import 'dart:io';

import 'package:coding_agent_core/coding_agent_core.dart';
import 'package:coding_agent_in_dart/src/tui.dart';
import 'package:nocterm/nocterm.dart';

const usage = '''
Usage: dart run coding_agent_in_dart [options]

With no options it uses Gemini, with the key in GEMINI_API_KEY.

  --provider <name>  use another provider:
                       ollama      models on this computer, free, no key
                       deepseek    key in DEEPSEEK_API_KEY
                       kimi        key in MOONSHOT_API_KEY
                       groq        key in GROQ_API_KEY
                       openrouter  key in OPENROUTER_API_KEY
  --chatgpt          use your ChatGPT plan (Plus or Pro): signs in with
                     ChatGPT in the browser the first time
  --model <name>     the model to use, instead of the provider's default
                     (Ollama and ChatGPT: the first one they list)
  --models           list the models you can use, with --provider or
                     --chatgpt
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

  if (args.indexOf('--provider') case final i when i >= 0) {
    final name = i + 1 < args.length ? args[i + 1] : '';
    final endpoint = Endpoint.named(name);
    if (endpoint == null) {
      print(
        'Error: no provider called "$name". Pick one of: '
        '${Endpoint.all.map((e) => e.id).join(', ')}',
      );
      return;
    }
    await _compatible(args, endpoint, settingsFile);
    return;
  }

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

/// The model --model names, if it gave one.
String? _wantedModel(List<String> args) {
  final i = args.indexOf('--model');
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> _compatible(
  List<String> args,
  Endpoint endpoint,
  File? settingsFile,
) async {
  String? key;
  if (endpoint.keyVariable case final variable?) {
    key = Platform.environment[variable] ?? '';
    if (key.isEmpty) {
      print(
        'Error: set $variable to use ${endpoint.name}. Make a key at '
        '${endpoint.keysUrl}',
      );
      return;
    }
  }

  var model = _wantedModel(args) ?? endpoint.defaultModel;
  if (model == null || args.contains('--models')) {
    final List<String> models;
    try {
      models = await CompatibleProvider.models(endpoint, apiKey: key);
    } on ProviderError catch (e) {
      print("Error: ${endpoint.name} didn't list its models: ${e.message}");
      return;
    }
    if (args.contains('--models')) {
      models.forEach(print);
      return;
    }
    if (models.isEmpty) {
      print(
        endpoint.local
            ? 'Error: Ollama has no models yet. Pull one first, like '
                  '`ollama pull gpt-oss:20b`.'
            : 'Error: ${endpoint.name} lists no models.',
      );
      return;
    }
    model = models.first;
  }

  await runApp(
    HarnessApp(
      provider: CompatibleProvider(endpoint, model: model, apiKey: key),
      model: model,
      settingsFile: settingsFile,
      plan: endpoint.local ? 'this computer' : null,
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
      await auth.signIn(
        onUrl: (url) => print('\n$url\n'),
        onRetry: () => print(
          'OpenAI needs one more sign-in to finish setting up the app. '
          'Your browser opens again; pick the same account. If it '
          "doesn't open, open this:",
        ),
      );
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

  final wanted = _wantedModel(args);
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
