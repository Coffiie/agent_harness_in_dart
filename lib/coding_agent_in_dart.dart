import 'dart:io';

import 'src/agent.dart';
import 'src/events.dart';
import 'src/gemini_provider.dart';
import 'src/tools.dart';

String divider() {
  return '-' * 20;
}

String toolSeparator() {
  return '┃';
}

String input() {
  stdout.write('${divider()}\n');
  stdout.write('You: ');
  final input = stdin.readLineSync() ?? '';
  stdout.write('${divider()}\n');
  return input;
}

void main(List<String> arguments) async {
  // fetch api key from environment variable setup in the terminal
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return;
  }

  final gemini = GeminiProvider(apiKey);
  final agent = Agent(gemini, fileTools());

  print(divider());
  print('Chat with ${gemini.model}: (press ctrl-c to exit)');
  print(divider());

  while (true) {
    final prompt = input();

    final events = prompt.contains('/compact')
        ? agent.compact()
        : agent.send(prompt);

    await for (final event in events) {
      switch (event) {
        case AssistantText(:final text):
          print('${gemini.model}: $text');
        case ToolStarted(:final label):
          print('${toolSeparator()} $label\n');
        case ToolFinished(:final output):
          print('${output.trimRight()}\n');
        case CompactionStarted():
          print('${toolSeparator()} Summarizing Conversation...\n');
        case Compacted(:final before, :final after):
          print(
            '${toolSeparator()} Compacted conversation from $before tokens to $after tokens',
          );
        case RateLimitWait(:final wait):
          print(
            "${toolSeparator()} Gemini's rate limit: waiting "
            '${wait.inSeconds}s, then trying again\n',
          );
        case AgentError(:final message):
          print('Error generating content: $message');
        case UsageReported():
          // the TUI's header shows these; the CLI doesn't
          break;
        case Asked(:final question):
          // the CLI has no askUser tool, so this never comes
          question.reply('');
      }
    }
  }
}
