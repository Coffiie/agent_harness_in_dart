import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'messages.dart';
import 'model_provider.dart';
import 'tools.dart';
import 'usage.dart';

const _baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models';

class GeminiProvider implements ModelProvider {
  GeminiProvider(
    this._apiKey, {
    this.model = 'gemini-3.1-flash-lite',
    http.Client? client,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.timeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  final String _apiKey;
  final http.Client _client;
  final String model;

  /// How long a request may take. After that it counts as lost, and the
  /// agent tries again, the way it does when Gemini is busy.
  final Duration timeout;

  // Every session shares this provider, so when Gemini says to slow down,
  // they all wait until [_pausedUntil] before the next request.
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  DateTime? _pausedUntil;

  // How many requests in a row Gemini was too busy for. Each wait doubles.
  var _busy = 0;

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async {
    final response = await _post('generateContent', {
      if (system != null)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': messages.map(_toContent).toList(),
      if (tools.isNotEmpty)
        'tools': [
          {'functionDeclarations': tools.map(_toDeclaration).toList()},
        ],
    });

    final candidates = response['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('receiving candidates');
    }

    final content = candidates.first['content'] as Map<String, dynamic>?;
    if (content == null) {
      throw Exception('model content is null');
    }

    return Message(
      Role.assistant,
      [
        for (final part in content['parts'] as List<dynamic>)
          if (part['functionCall'] case final Map<String, dynamic> call)
            ToolCall(
              call['name'] as String,
              call['args'] as Map<String, dynamic>? ?? {},
            )
          else if (part['text'] case final String text)
            TextPart(text),
      ],
      raw: content,
      usage: _usage(response['usageMetadata']),
    );
  }

  // Gemini bills thinking tokens as output, and counts cached tokens inside
  // promptTokenCount.
  Usage? _usage(Object? meta) {
    if (meta is! Map) return null;
    int count(String key) => (meta[key] as num?)?.toInt() ?? 0;
    return Usage(
      input: count('promptTokenCount'),
      cached: count('cachedContentTokenCount'),
      output: count('candidatesTokenCount') + count('thoughtsTokenCount'),
    );
  }

  @override
  Future<int> countTokens(List<Message> messages) async {
    final response = await _post('countTokens', {
      'contents': messages.map(_toContent).toList(),
    });
    return response['totalTokens'] as int;
  }

  Map<String, dynamic> _toContent(Message message) {
    // this is what preserves thoughtSignature
    if (message.raw case final Map<String, dynamic> raw) return raw;

    return {
      'role': message.role == Role.user ? 'user' : 'model',
      'parts': [
        for (final part in message.parts)
          switch (part) {
            TextPart(:final text) => {'text': text},
            ToolCall(:final name, :final args) => {
              'functionCall': {'name': name, 'args': args},
            },
            ToolResult(:final name, :final output) => {
              'functionResponse': {'name': name, 'response': output},
            },
          },
      ],
    };
  }

  Map<String, dynamic> _toDeclaration(Tool tool) => {
    'name': tool.name,
    'description': tool.description,
    'parameters': _upperCaseTypes(tool.parameters),
  };

  dynamic _upperCaseTypes(dynamic schema) => schema is Map
      ? schema.map(
          (key, value) => MapEntry(
            key,
            key == 'type' ? value.toUpperCase() : _upperCaseTypes(value),
          ),
        )
      : schema;

  Future<Map<String, dynamic>> _post(
    String method,
    Map<String, dynamic> body,
  ) async {
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
            Uri.parse('$_baseUrl/$model:$method'),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': _apiKey,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      final wait = _pause(Duration(seconds: min(5 << _busy++, 60)));
      throw TryLater(
        408,
        "no answer after ${timeout.inSeconds}s",
        retryAfter: wait,
      );
    }

    final status = response.statusCode;
    if (status == 429 || _busyStatuses.contains(status)) {
      final wait = _pause(
        _retryDelay(response.body) ??
            (status == 429
                ? const Duration(seconds: 10)
                : Duration(seconds: min(5 << _busy++, 60))),
      );
      final message = _message(response.body);
      throw status == 429
          ? RateLimited(message, retryAfter: wait)
          : TryLater(status, message, retryAfter: wait);
    }
    if (status != 200) throw ProviderError(status, _message(response.body));
    _busy = 0;

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // Holds every request back for [wait], unless they're held longer already.
  Duration _pause(Duration wait) {
    final until = _clock().add(wait);
    if (_pausedUntil == null || until.isAfter(_pausedUntil!)) {
      _pausedUntil = until;
    }
    return wait;
  }
}

// Gemini is overloaded, or failed on its side: worth another try.
const _busyStatuses = {500, 502, 503, 504};

// The first line of the error's message, or the start of the body when it
// isn't Gemini's JSON.
String _message(String body) {
  try {
    if (jsonDecode(body) case {'error': {'message': final String message}}) {
      return message.trim().split('\n').first;
    }
  } on FormatException {
    // not JSON
  }
  final text = body.trim();
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

// How long Gemini asked to wait, from the RetryInfo in a 429: "34s".
Duration? _retryDelay(String body) {
  try {
    final details = (jsonDecode(body) as Map)['error']['details'] as List;
    for (final detail in details) {
      if (detail case {'retryDelay': final String delay}) {
        final seconds = double.tryParse(delay.replaceAll('s', ''));
        if (seconds != null) {
          return Duration(milliseconds: (seconds * 1000).round());
        }
      }
    }
  } catch (_) {
    // no RetryInfo
  }
  return null;
}
