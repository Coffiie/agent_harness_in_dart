import 'dart:io';

import 'package:coding_agent_in_dart/src/gemini_provider.dart';
import 'package:coding_agent_in_dart/src/sandbox.dart';
import 'package:coding_agent_in_dart/src/tui.dart';
import 'package:nocterm/nocterm.dart';

Future<void> main() async {
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return;
  }

  final gemini = GeminiProvider(apiKey);
  stdout.writeln('Starting the sandbox…');
  final sandbox = await Sandbox.start(Directory.current.path);
  if (sandbox.problem case final problem?) {
    stdout.writeln(
      "The sandbox didn't start: $problem. The agent's tools only run "
      'inside it, so they will refuse until it does.',
    );
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  await runApp(
    HarnessApp(
      provider: gemini,
      model: gemini.model,
      settingsFile: home == null
          ? null
          : File('$home/.config/coding_agent_in_dart/settings.json'),
      sandbox: sandbox,
    ),
  );
}
