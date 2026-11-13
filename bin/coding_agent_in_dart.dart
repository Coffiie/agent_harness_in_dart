import 'dart:io';

import 'package:coding_agent_in_dart/src/chatgpt_auth.dart';
import 'package:coding_agent_in_dart/src/chatgpt_provider.dart';
import 'package:coding_agent_in_dart/src/gemini_provider.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/tui.dart';
import 'package:nocterm/nocterm.dart';

const usage = '''
Usage: dart run coding_agent_in_dart [options]

With no options it uses Gemini, with the key in GEMINI_API_KEY.

  --chatgpt          use your ChatGPT plan (Plus or Pro): signs in with
                     ChatGPT in the browser the first time
  --model <slug>     the ChatGPT model to use, instead of the first one
                     your account lists
  --models           list the ChatGPT models your account can use
  --sign-out         sign out of ChatGPT
''';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(usage);
    return;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final config = home == null ? null : '$home/.config/coding_agent_in_dart';
  final settingsFile = config == null ? null : File('$config/settings.json');

  if (args.any(
    (a) => a == '--chatgpt' || a == '--sign-out' || a == '--models',
  )) {
    if (config == null) {
      print("Error: can't find your home folder to keep the sign-in in.");
      return;
    }
    await _chatGpt(
      args,
      ChatGptAuth(File('$config/chatgpt.json')),
      settingsFile,
    );
    return;
  }

  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    print(
      'Error: Please set your GEMINI_API_KEY environment variable, or run '
      'with --chatgpt to use your ChatGPT plan.',
    );
    return;
  }

  final gemini = GeminiProvider(apiKey);
  await runApp(
    HarnessApp(
      provider: gemini,
      model: gemini.model,
      settingsFile: settingsFile,
    ),
  );
}

Future<void> _chatGpt(
  List<String> args,
  ChatGptAuth auth,
  File? settingsFile,
) async {
  if (args.contains('--sign-out')) {
    await auth.signOut();
    print('Signed out of ChatGPT.');
    return;
  }

  if (!auth.signedIn) {
    print(
      'Sign in with ChatGPT to use your ChatGPT plan here. Your browser '
      "opens to OpenAI's sign-in. If it doesn't, open this:",
    );
    try {
      await auth.signIn(onUrl: (url) => print('\n$url\n'));
    } on SignInError catch (e) {
      print('Error: $e');
      return;
    }
    final email = auth.account?.email;
    print('Signed in${email == null ? '' : ' as $email'}.');
  }

  final List<ChatGptModel> models;
  try {
    models = await ChatGptProvider.models(auth);
  } on ProviderError catch (e) {
    print("Error: ChatGPT didn't list your models: $e");
    return;
  } on SignInError catch (e) {
    print('Error: $e Run it with --chatgpt to sign in again.');
    return;
  }
  if (models.isEmpty) {
    print('Error: your ChatGPT account lists no models to use here.');
    return;
  }
  if (args.contains('--models')) {
    for (final model in models) {
      print('${model.slug}  ${model.name}');
    }
    return;
  }

  final i = args.indexOf('--model');
  final wanted = i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  final model = wanted == null
      ? models.first
      : models.where((m) => m.slug == wanted).firstOrNull;
  if (model == null) {
    print(
      'Error: your account has no model called $wanted. It has: '
      '${models.map((m) => m.slug).join(', ')}',
    );
    return;
  }

  // OpenAI asks apps to say so the first time requests use the plan
  String? welcome;
  if (!auth.welcomed) {
    welcome =
        "You're using your ChatGPT plan. What you ask here counts toward its "
        'usage limits, the same ones as ChatGPT and your other apps. Manage '
        'usage: $chatGptUsageUrl';
    auth.welcomed = true;
    await auth.save();
  }

  await runApp(
    HarnessApp(
      provider: ChatGptProvider(auth, model: model.slug),
      model: model.slug,
      settingsFile: settingsFile,
      plan: 'ChatGPT plan',
      welcome: welcome,
    ),
  );
}
