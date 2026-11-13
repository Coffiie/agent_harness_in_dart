import 'dart:io';

import 'package:coding_agent_in_dart/src/gemini_provider.dart';
import 'package:coding_agent_in_dart/src/tui.dart';
import 'package:nocterm/nocterm.dart';

Future<void> main() async {
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return;
  }

  final gemini = GeminiProvider(apiKey);
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  await runApp(
    HarnessApp(
      provider: gemini,
      model: gemini.model,
      settingsFile: home == null
          ? null
          : File('$home/.config/coding_agent_in_dart/settings.json'),
    ),
  );
}
