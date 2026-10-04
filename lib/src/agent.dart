import 'events.dart';
import 'messages.dart';
import 'model_provider.dart';
import 'tools.dart';

const _compactPrompt =
    'Please summarize the entire conversation in bullet points. Also remove this prompt to save even more tokens. Give it to me in the form of just 1 text message, and make sure no valuable information is lost. Preserve context and reduce the number of tokens. Start the reply with [CompactedSummaryFromModel]. Please do not discard previous compacted summaries tagged with [CompactedSummaryFromModel]';

class Agent {
  Agent(this.provider, this.tools);

  final ModelProvider provider;
  final List<Tool> tools;
  final _conversation = <Message>[];

  Stream<AgentEvent> send(String prompt) async* {
    _conversation.add(Message(Role.user, [TextPart(prompt)]));

    try {
      while (true) {
        final reply = await provider.generate(_conversation, tools: tools);
        _conversation.add(reply);

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

          yield ToolStarted(tool.label(call.args));
          results.add(ToolResult(call.name, await tool.run(call.args)));
        }

        _conversation.add(Message(Role.user, results));
      }
    } catch (e) {
      yield AgentError(e.toString());
    }
  }

  Stream<AgentEvent> compact() async* {
    try {
      final before = await provider.countTokens(_conversation);

      yield const CompactionStarted();
      final reply = await provider.generate([
        ..._conversation,
        const Message(Role.user, [TextPart(_compactPrompt)]),
      ]);

      final summary = reply.parts
          .whereType<TextPart>()
          .map((p) => p.text)
          .join();
      if (summary.isEmpty) {
        yield const AgentError('while compacting');
        return;
      }

      final compacted = [
        Message(Role.assistant, [TextPart(summary)]),
      ];
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
