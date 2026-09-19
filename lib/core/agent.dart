import 'events.dart';
import 'message.dart';
import 'session.dart';
import 'tool.dart';
import '../providers/model_provider.dart';

const _defaultMaxToolIterations = 20;

const _compactPrompt =
    'Please summarize the entire conversation in bullet points. Also remove this prompt to save even more tokens. Give it to me in the form of just 1 text message, and make sure no valuable information is lost. Preserve context and reduce the number of tokens. Start the reply with [CompactedSummaryFromModel]. Please do not discard previous compacted summaries tagged with [CompactedSummaryFromModel]';

/// UI-free coding-agent harness: model loop + tools, emits [AgentEvent]s.
final class Agent {
  Agent({
    required ModelProvider provider,
    required ToolRegistry tools,
    Session? session,
    int maxToolIterations = _defaultMaxToolIterations,
  }) : _provider = provider,
       _tools = tools,
       _session = session ?? Session(),
       _maxToolIterations = maxToolIterations;

  final ModelProvider _provider;
  final ToolRegistry _tools;
  final Session _session;
  final int _maxToolIterations;

  ModelProvider get provider => _provider;
  Session get session => _session;

  /// Run one user turn (may include multiple tool iterations).
  Stream<AgentEvent> runTurn(String userText) async* {
    _session.add(
      Message(role: Role.user, parts: [TextPart(userText)]),
    );

    var iterations = 0;
    try {
      while (true) {
        if (iterations++ >= _maxToolIterations) {
          yield const AgentError(
            'Exceeded maximum tool iterations for this turn',
          );
          return;
        }

        final response = await _provider.complete(
          CompletionRequest(
            messages: _session.messages,
            tools: _tools.specs,
            enableTools: true,
          ),
        );

        final assistant = response.message;
        _session.add(assistant);

        for (final part in assistant.parts) {
          if (part is TextPart && part.text.isNotEmpty) {
            yield AssistantText(part.text);
          }
        }

        final toolCalls = assistant.parts.whereType<ToolCallPart>().toList();
        if (toolCalls.isEmpty) {
          yield const TurnComplete();
          return;
        }

        final results = <ToolResultPart>[];
        for (final call in toolCalls) {
          yield ToolStarted(name: call.name, args: call.args);
          final result = await _tools.execute(call.name, call.args);
          yield ToolFinished(
            name: call.name,
            args: call.args,
            result: result,
          );
          results.add(
            ToolResultPart(
              id: call.id,
              name: call.name,
              response: result,
            ),
          );
        }

        _session.add(Message(role: Role.tool, parts: results));
      }
    } catch (e) {
      yield AgentError('Error generating content: $e');
    }
  }

  /// Summarize history to reduce tokens (preserves compact marker semantics).
  Stream<AgentEvent> compact() async* {
    yield const CompactProgress();

    final before = await _provider.countTokens(_session.messages) ?? -1;

    final working = List<Message>.of(_session.messages)
      ..add(
        Message(role: Role.user, parts: [const TextPart(_compactPrompt)]),
      );

    try {
      final response = await _provider.complete(
        CompletionRequest(
          messages: working,
          enableTools: false,
        ),
      );

      final text = response.message.parts
          .whereType<TextPart>()
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .join('\n');

      if (text.isEmpty) {
        yield const AgentError('Error: while compacting');
        return;
      }

      _session.replaceAll([
        Message(
          role: Role.assistant,
          parts: [TextPart(text)],
        ),
      ]);

      final after = await _provider.countTokens(_session.messages) ?? -1;
      yield CompactComplete(beforeTokens: before, afterTokens: after);
    } catch (e) {
      yield AgentError('Error generating content: $e');
    }
  }
}
