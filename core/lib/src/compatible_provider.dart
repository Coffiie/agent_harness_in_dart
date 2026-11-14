import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'messages.dart';
import 'model_provider.dart';
import 'tools.dart';
import 'usage.dart';

/// A service that speaks OpenAI's Chat Completions format: where it is,
/// what it's called, and where its key comes from.
class Endpoint {
  const Endpoint({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.keyVariable,
    this.keysUrl,
    this.defaultModel,
    this.local = false,
    this.timeout = const Duration(seconds: 90),
  });

  /// What `--provider` takes: "deepseek".
  final String id;

  /// What the user sees: "DeepSeek".
  final String name;

  /// Requests go to `$baseUrl/chat/completions`.
  final String baseUrl;

  /// The environment variable the API key is in. Null for a server on this
  /// computer, which takes no key.
  final String? keyVariable;

  /// Where to make a key.
  final String? keysUrl;

  /// The model to use when none is picked. Null means the first one the
  /// endpoint lists.
  final String? defaultModel;

  /// Runs on this computer, so it costs nothing.
  final bool local;

  /// How long one answer may take. A model on this computer writes slower
  /// than one in a data center, so it gets longer.
  final Duration timeout;

  static const deepSeek = Endpoint(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    keyVariable: 'DEEPSEEK_API_KEY',
    keysUrl: 'https://platform.deepseek.com/api_keys',
    defaultModel: 'deepseek-flash',
  );

  static const kimi = Endpoint(
    id: 'kimi',
    name: 'Kimi',
    baseUrl: 'https://api.moonshot.ai/v1',
    keyVariable: 'MOONSHOT_API_KEY',
    keysUrl: 'https://platform.moonshot.ai/console/api-keys',
    defaultModel: 'kimi-k2.7-code',
  );

  static const groq = Endpoint(
    id: 'groq',
    name: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    keyVariable: 'GROQ_API_KEY',
    keysUrl: 'https://console.groq.com/keys',
    defaultModel: 'openai/gpt-oss-120b',
  );

  static const openRouter = Endpoint(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    keyVariable: 'OPENROUTER_API_KEY',
    keysUrl: 'https://openrouter.ai/keys',
    defaultModel: 'nvidia/nemotron-3-ultra-550b-a55b:free',
  );

  static const ollama = Endpoint(
    id: 'ollama',
    name: 'Ollama',
    baseUrl: 'http://localhost:11434/v1',
    local: true,
    timeout: Duration(minutes: 5),
  );

  static const all = [deepSeek, kimi, groq, openRouter, ollama];

  /// The endpoint `--provider` names, if there is one.
  static Endpoint? named(String id) =>
      all.where((e) => e.id == id.toLowerCase()).firstOrNull;
}

/// Talks to any [Endpoint] that speaks OpenAI's Chat Completions format:
/// DeepSeek, Kimi, Groq, OpenRouter, or Ollama on this computer. The
/// harness keeps its own loop and runs the tools itself, as with Gemini.
class CompatibleProvider implements ModelProvider {
  CompatibleProvider(
    this.endpoint, {
    required this.model,
    String? apiKey,
    http.Client? client,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    Duration? timeout,
  }) : _apiKey = apiKey,
       _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed,
       timeout = timeout ?? endpoint.timeout;

  final Endpoint endpoint;
  final String model;

  /// How long a request may take before it counts as lost and is tried
  /// again.
  final Duration timeout;

  final String? _apiKey;
  final http.Client _client;

  // Every session shares this provider, so when the endpoint says to slow
  // down they all wait until [_pausedUntil].
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  DateTime? _pausedUntil;
  var _busy = 0;

  @override
  String get name => endpoint.name;

  /// The models [endpoint] has: for Ollama, the ones pulled on this
  /// computer.
  static Future<List<String>> models(
    Endpoint endpoint, {
    String? apiKey,
    http.Client? client,
  }) async {
    final http.Response response;
    try {
      response = await (client ?? http.Client()).get(
        Uri.parse('${endpoint.baseUrl}/models'),
        headers: {'Authorization': ?_bearer(apiKey)},
      );
    } on SocketException {
      throw ProviderError(0, _unreachable(endpoint));
    } on http.ClientException {
      throw ProviderError(0, _unreachable(endpoint));
    }
    if (response.statusCode != 200) {
      throw ProviderError(
        response.statusCode,
        _explain(endpoint, response.statusCode, _message(response.body)),
      );
    }
    final json = jsonDecode(response.body);
    return [
      if (json case {'data': final List data})
        for (final model in data)
          if (model case {'id': final String id}) id,
    ];
  }

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async {
    final reply = await _post({
      'model': model,
      'messages': [
        if (system != null) {'role': 'system', 'content': system},
        ...chat(messages),
      ],
      if (tools.isNotEmpty)
        'tools': [
          for (final tool in tools)
            {
              'type': 'function',
              'function': {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
        ],
    });

    final choices = reply['choices'];
    if (choices is! List || choices.isEmpty) {
      throw ProviderError(0, '${endpoint.name} sent no answer');
    }
    final message = (choices.first as Map)['message'] as Map? ?? const {};
    final calls = [
      for (final (i, call) in (message['tool_calls'] as List? ?? []).indexed)
        if (call case {'function': {'name': final String name}})
          (
            id: call['id'] as String? ?? 'call_$i',
            name: name,
            arguments: (call['function'] as Map)['arguments'],
          ),
    ];
    final text = message['content'];
    return Message(
      Role.assistant,
      [
        if (text is String && text.trim().isNotEmpty) TextPart(text),
        for (final call in calls) ToolCall(call.name, _args(call.arguments)),
      ],
      raw: {
        'role': 'assistant',
        'content': text is String ? text : '',
        if (calls.isNotEmpty)
          'tool_calls': [
            for (final call in calls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': call.arguments is String
                      ? call.arguments
                      : jsonEncode(call.arguments ?? {}),
                },
              },
          ],
        // DeepSeek's thinking: it asks for it back while tools run
        if (message['reasoning_content'] case final String thought)
          'reasoning_content': thought,
      },
      usage: _usage(reply['usage']),
    );
  }

  /// The chat as Chat Completions messages. A reply this provider wrote
  /// goes back as it came; a tool result goes with the id of the call it
  /// answers.
  static List<Map<String, dynamic>> chat(List<Message> messages) {
    final out = <Map<String, dynamic>>[];
    var calls = <String>[];
    var made = 0;
    for (final message in messages) {
      if (message.role == Role.assistant) {
        if (message.raw case {'role': 'assistant'} && final Map raw) {
          out.add(raw.cast<String, dynamic>());
          calls = [
            for (final call in raw['tool_calls'] as List? ?? [])
              (call as Map)['id'] as String,
          ];
          continue;
        }
        // written here, like a compacted summary, or by another provider
        calls = [];
        final text = [
          for (final part in message.parts)
            if (part case TextPart(:final text)) text,
        ].join('\n\n');
        final toolCalls = <Map<String, dynamic>>[];
        for (final part in message.parts) {
          if (part case ToolCall(:final name, :final args)) {
            final id = 'call_harness_${made++}';
            calls.add(id);
            toolCalls.add({
              'id': id,
              'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(args)},
            });
          }
        }
        out.add({
          'role': 'assistant',
          'content': text,
          if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
        });
        continue;
      }
      var answered = 0;
      final said = <String>[];
      for (final part in message.parts) {
        switch (part) {
          case ToolResult(:final output):
            out.add({
              'role': 'tool',
              'tool_call_id': answered < calls.length
                  ? calls[answered]
                  : 'call_harness_${made++}',
              'content': jsonEncode(output),
            });
            answered++;
          case TextPart(:final text) when text.isNotEmpty:
            said.add(text);
          default:
        }
      }
      if (said.isNotEmpty) {
        out.add({'role': 'user', 'content': said.join('\n\n')});
      }
    }
    return out;
  }

  /// A guess, about four characters a token: these endpoints have no
  /// counter.
  @override
  Future<int> countTokens(List<Message> messages) async =>
      (jsonEncode(chat(messages)).length / 4).ceil();

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    while (true) {
      final until = _pausedUntil;
      if (until == null) break;
      final left = until.difference(_clock());
      if (left <= Duration.zero) break;
      await _sleep(left);
    }

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('${endpoint.baseUrl}/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': ?_bearer(_apiKey),
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw TryLater(
        408,
        'no answer after ${timeout.inSeconds}s',
        retryAfter: _pause(Duration(seconds: min(5 << _busy++, 60))),
      );
    } on SocketException {
      throw ProviderError(0, _unreachable(endpoint));
    } on http.ClientException {
      throw ProviderError(0, _unreachable(endpoint));
    }

    final status = response.statusCode;
    final said = _message(response.body);
    if (status == 429 || _busyStatuses.contains(status)) {
      final asked = int.tryParse(response.headers['retry-after'] ?? '');
      final wait = _pause(
        asked != null
            ? Duration(seconds: asked)
            : status == 429
            ? const Duration(seconds: 10)
            : Duration(seconds: min(5 << _busy++, 60)),
      );
      throw status == 429
          ? RateLimited(said, retryAfter: wait)
          : TryLater(status, said, retryAfter: wait);
    }
    if (status != 200) {
      throw ProviderError(status, _explain(endpoint, status, said, model));
    }
    _busy = 0;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Duration _pause(Duration wait) {
    final until = _clock().add(wait);
    if (_pausedUntil == null || until.isAfter(_pausedUntil!)) {
      _pausedUntil = until;
    }
    return wait;
  }

  static String? _bearer(String? key) =>
      key == null || key.isEmpty ? null : 'Bearer $key';

  static Map<String, dynamic> _args(Object? arguments) {
    if (arguments is Map<String, dynamic>) return arguments;
    try {
      final args = jsonDecode('${arguments ?? '{}'}');
      return args is Map<String, dynamic> ? args : {};
    } on FormatException {
      return {};
    }
  }

  // DeepSeek reports its cache as prompt_cache_hit_tokens; OpenAI's format,
  // which the others follow, as prompt_tokens_details.cached_tokens.
  static Usage? _usage(Object? usage) {
    if (usage is! Map) return null;
    int count(Object? n) => (n as num?)?.toInt() ?? 0;
    final details = usage['prompt_tokens_details'];
    return Usage(
      input: count(usage['prompt_tokens']),
      cached: count(
        usage['prompt_cache_hit_tokens'] ??
            (details is Map ? details['cached_tokens'] : null),
      ),
      output: count(usage['completion_tokens']),
    );
  }
}

// Worth another try.
const _busyStatuses = {500, 502, 503, 504};

String _unreachable(Endpoint endpoint) => endpoint.local
    ? "Can't reach ${endpoint.name} at ${Uri.parse(endpoint.baseUrl).authority}. "
          'Open the Ollama app, or run `ollama serve`.'
    : "Can't reach ${endpoint.name}. Check your connection.";

// What to do about an error, where the harness knows.
String _explain(Endpoint endpoint, int status, String said, [String? model]) =>
    switch (status) {
      401 || 403 when endpoint.keyVariable != null =>
        '${endpoint.name} turned down the key in ${endpoint.keyVariable}: '
            '$said',
      402 =>
        'Your ${endpoint.name} balance has run out: $said. Top it up, '
            'then try again.',
      404 when endpoint.local && model != null =>
        "${endpoint.name} doesn't have $model. Pull it with "
            '`ollama pull $model`.',
      _ => said,
    };

// The error's message, from OpenAI's {"error": {"message": ...}} shape and
// the ones close to it, or the start of the body.
String _message(String body) {
  try {
    switch (jsonDecode(body)) {
      case {'error': {'message': final String message}}:
        return message.trim().split('\n').first;
      case {'error': final String message}:
        return message.trim().split('\n').first;
      case {'message': final String message}:
        return message.trim().split('\n').first;
    }
  } on FormatException {
    // not JSON
  }
  final text = body.trim();
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}
