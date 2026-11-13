import 'events.dart';
import 'messages.dart';
import 'model_provider.dart';
import 'tools.dart';
import 'usage.dart';

const _compactPrompt =
    'Please summarize the entire conversation in bullet points. Also remove this prompt to save even more tokens. Give it to me in the form of just 1 text message, and make sure no valuable information is lost. Preserve context and reduce the number of tokens. Start the reply with [CompactedSummaryFromModel]. Please do not discard previous compacted summaries tagged with [CompactedSummaryFromModel]';

const _handoffPrompt =
    'The user is starting a new, separate chat with the prompt below. Does '
    'that prompt depend on anything in this conversation, like files, code, '
    'names or decisions from it? If it does not, reply with exactly NONE. If '
    'it does, reply with a short summary in bullet points of only what the '
    'new chat needs to know. Start that reply with '
    '[CompactedSummaryFromModel].\n\nThe new prompt: ';

/// What [Agent.handoff] decided: a summary for the new chat to start from,
/// or null when the prompt needs nothing from this one.
class Handoff {
  const Handoff(this.summary, {this.usage});

  final String? summary;

  /// What the call cost, when there was one.
  final Usage? usage;
}

class Agent {
  /// Starts from [conversation] when given one, for /fork and /new.
  Agent(
    this.provider,
    this.tools, {
    this.system,
    Iterable<Message> conversation = const [],
  }) {
    _conversation.addAll(conversation);
  }

  final ModelProvider provider;
  final List<Tool> tools;
  final String? system;
  final _conversation = <Message>[];

  /// The chat so far.
  List<Message> get conversation => List.unmodifiable(_conversation);

  /// Starts a chat from a summary, the way /compact leaves one.
  static List<Message> summarized(String summary) => [
    Message(Role.assistant, [TextPart(summary)]),
  ];

  // Things the model should know that happened outside the chat, like
  // /undo. They go in front of the next prompt, or into /compact's request.
  final _notes = <String>[];

  /// Tells the model [text] with the next request.
  void note(String text) => _notes.add(text);

  List<Part> _withNotes(String text) {
    final parts = [for (final note in _notes) TextPart(note), TextPart(text)];
    _notes.clear();
    return parts;
  }

  Stream<AgentEvent> send(String prompt) async* {
    _conversation.add(Message(Role.user, _withNotes(prompt)));

    try {
      while (true) {
        final reply = await provider.generate(
          _conversation,
          tools: tools,
          system: system,
        );
        _conversation.add(reply);
        if (reply.usage case final usage?) yield UsageReported(usage);

        for (final part in reply.parts) {
          if (part is TextPart && part.text.isNotEmpty) {
            yield AssistantText(part.text);
          }
        }

        final calls = reply.parts.whereType<ToolCall>();

        //exit loop if only text is returned, this means no function calls
        if (calls.isEmpty) {
          return;
        }

        final results = <Part>[];
        for (final call in calls) {
          final tool = tools.where((t) => t.name == call.name).firstOrNull;
          if (tool == null) {
            results.add(
              ToolResult(call.name, {
                'error': 'Unknown function: ${call.name}',
              }),
            );
            continue;
          }

          yield ToolStarted(
            tool.label(call.args),
            diff: tool.diff?.call(call.args) ?? const [],
          );
          if (tool.ask?.call(call.args) case final question?) {
            yield Asked(question);
            final answer = await question.answer;
            results.add(ToolResult(call.name, {'answer': answer}));
            continue;
          }
          final result = await tool.run(call.args);
          results.add(ToolResult(call.name, result));
          if (_shown(result) case final shown?) yield shown;
        }

        _conversation.add(Message(Role.user, results));
      }
    } catch (e) {
      yield AgentError(e.toString());
    }
  }

  // What the user sees of a tool's result: a command's output, or an error.
  static ToolFinished? _shown(Map<String, dynamic> result) {
    if (result['error'] case final String error) {
      return ToolFinished(error, failed: true);
    }
    if (result case {'status': 'error', 'message': final String message}) {
      return ToolFinished(message, failed: true);
    }
    if (result['output'] case final String output) {
      return ToolFinished(output, failed: result['exitCode'] != 0);
    }
    return null;
  }

  /// Asks the model, in one call that leaves this chat as it is, whether
  /// [prompt] needs anything from this chat. With no chat yet there's
  /// nothing to ask.
  Future<Handoff> handoff(String prompt) async {
    if (_conversation.isEmpty) return const Handoff(null);

    final reply = await provider.generate([
      ..._conversation,
      Message(Role.user, [TextPart('$_handoffPrompt$prompt')]),
    ], system: system);
    final text = reply.parts
        .whereType<TextPart>()
        .map((p) => p.text)
        .join()
        .trim();
    final none = text.isEmpty || text.startsWith('NONE');
    return Handoff(none ? null : text, usage: reply.usage);
  }

  Stream<AgentEvent> compact() async* {
    try {
      final before = await provider.countTokens(_conversation);

      yield const CompactionStarted();
      final reply = await provider.generate([
        ..._conversation,
        Message(Role.user, _withNotes(_compactPrompt)),
      ], system: system);
      if (reply.usage case final usage?) yield UsageReported(usage);

      final summary = reply.parts
          .whereType<TextPart>()
          .map((p) => p.text)
          .join();
      if (summary.isEmpty) {
        yield const AgentError('while compacting');
        return;
      }

      final compacted = summarized(summary);
      final after = await provider.countTokens(compacted);

      _conversation
        ..clear()
        ..addAll(compacted);
      yield Compacted(before, after);
    } catch (e) {
      yield AgentError(e.toString());
    }
  }
}
