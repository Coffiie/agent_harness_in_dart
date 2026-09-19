import 'dart:io';

import '../../core/agent.dart';
import '../../core/events.dart';
import '../../core/tool.dart';
import '../../providers/gemini/gemini_provider.dart';
import '../../providers/model_provider.dart';
import '../../tools/file_tools.dart';

String divider() => '-' * 20;

String toolSeparator() => '┃';

String readUserInput() {
  stdout.write('${divider()}\n');
  stdout.write('You: ');
  final input = stdin.readLineSync() ?? '';
  stdout.write('${divider()}\n');
  return input;
}

/// Terminal REPL that drives an [Agent] via [AgentEvent]s.
final class TerminalApp {
  TerminalApp({Agent? agent, ModelProvider? provider})
    : _agent =
          agent ??
          Agent(
            provider: provider ?? GeminiProvider(),
            tools: ToolRegistry(fileTools()),
          );

  final Agent _agent;

  Future<void> run() async {
    final modelName = _agent.provider.displayName;
    print(divider());
    print('Chat with $modelName: (press ctrl-c to exit)');
    print(divider());

    while (true) {
      final prompt = readUserInput();

      if (prompt.contains('/compact')) {
        await for (final event in _agent.compact()) {
          _render(event, modelName);
        }
        continue;
      }

      await for (final event in _agent.runTurn(prompt)) {
        _render(event, modelName);
      }
    }
  }

  void _render(AgentEvent event, String modelName) {
    switch (event) {
      case AssistantText(:final text):
        print('$modelName: $text');
      case ToolStarted(:final name, :final args):
        final argSummary = args.entries
            .map((e) => '${e.key}: ${e.value}')
            .join(', ');
        print('${toolSeparator()} ${_formatToolName(name)}($argSummary)\n');
      case ToolFinished():
        break;
      case TurnComplete():
        break;
      case CompactProgress():
        print('${toolSeparator()} Summarizing Conversation...\n');
      case CompactComplete(:final beforeTokens, :final afterTokens):
        print(
          '${toolSeparator()} Compacted conversation from $beforeTokens tokens to $afterTokens tokens',
        );
      case AgentError(:final message):
        print(message);
    }
  }

  String _formatToolName(String name) {
    if (name.isEmpty) return name;
    return '${name[0].toUpperCase()}${name.substring(1)}';
  }
}
