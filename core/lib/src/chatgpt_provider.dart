import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'chatgpt_auth.dart';
import 'messages.dart';
import 'model_provider.dart';
import 'tools.dart';
import 'usage.dart';

/// Where the user sees and manages their ChatGPT plan's usage.
const chatGptUsageUrl = 'https://chatgpt.com/settings/usage';

/// A model the signed-in ChatGPT account can use.
class ChatGptModel {
  const ChatGptModel(this.slug, this.name);

  /// What a request names it.
  final String slug;

  /// What the user sees.
  final String name;
}

/// Talks to OpenAI's Responses API with the user's ChatGPT plan, through a
/// [ChatGptAuth] sign-in. The harness keeps its own loop: it sends the whole
/// chat each time (`store: false`), with its own tools and instructions,
/// and runs the tools itself.
class ChatGptProvider implements ModelProvider {
  ChatGptProvider(
    this.auth, {
    required this.model,
    http.Client? client,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.timeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  static const _base = 'https://api.openai.com/v1';

  // The tools go in one namespace, the way OpenAI asks apps on this route
  // to send them; [_namespaced] turns off if the route says it can't.
  static const _namespace = 'harness';

  final ChatGptAuth auth;
  final String model;

  /// How long the answer may go quiet before it counts as lost.
  final Duration timeout;
  final http.Client _client;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  var _namespaced = true;
  DateTime? _pausedUntil;
  var _busy = 0;

  @override
  String get name => 'ChatGPT';

  /// The models the signed-in account can pick, in OpenAI's order.
  static Future<List<ChatGptModel>> models(
    ChatGptAuth auth, {
    http.Client? client,
  }) async {
    final response = await (client ?? http.Client()).get(
      Uri.parse('$_base/models'),
      headers: {'Authorization': 'Bearer ${await auth.accessToken()}'},
    );
    if (response.statusCode != 200) {
      throw ProviderError(response.statusCode, _message(response.body));
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return [
      for (final model in json['models'] as List? ?? const [])
        if (model case {'visibility': 'list', 'slug': final String slug})
          ChatGptModel(slug, model['display_name'] as String? ?? slug),
    ];
  }

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async {
    var refresh = false;
    for (var attempt = 0; ; attempt++) {
      try {
        return await _generate(messages, tools, system, refresh: refresh);
      } on _TryAgain catch (again) {
        if (attempt >= 2) throw ProviderError(again.status, again.message);
        refresh = again.refresh;
      } on SignInError catch (e) {
        throw ProviderError(401, '$e Run it with --chatgpt to sign in again.');
      }
    }
  }

  Future<Message> _generate(
    List<Message> messages,
    List<Tool> tools,
    String? system, {
    required bool refresh,
  }) async {
    if (_pausedUntil case final until?) {
      final left = until.difference(_clock());
      if (left > Duration.zero) await _sleep(left);
    }

    final request = http.Request('POST', Uri.parse('$_base/responses'))
      ..headers.addAll({
        'Authorization': 'Bearer ${await auth.accessToken(force: refresh)}',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': model,
        'store': false,
        'stream': true,
        'instructions': ?system,
        'input': input(messages),
        if (tools.isNotEmpty) 'tools': _tools(tools),
      });

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw _lost();
    }

    if (response.statusCode != 200) {
      _fail(response.statusCode, await response.stream.bytesToString());
    }

    final items = <Map<String, dynamic>>[];
    Map<String, dynamic>? done;
    try {
      await for (final event in _events(response.stream).timeout(timeout)) {
        switch (event['type']) {
          case 'response.output_item.done':
            items.add(event['item'] as Map<String, dynamic>);
          case 'response.completed':
            done = event['response'] as Map<String, dynamic>? ?? {};
          case 'response.failed':
            final error = (event['response'] as Map?)?['error'] as Map?;
            _failCode(error?['code'] as String?, error?['message'], 500);
          case 'response.incomplete':
            final why = (event['response'] as Map?)?['incomplete_details'];
            throw ProviderError(
              0,
              'the answer stopped early'
              '${why is Map && why['reason'] != null ? ': ${why['reason']}' : ''}',
            );
          case 'error':
            _failCode(event['code'] as String?, event['message'], 500);
        }
        if (done != null) break;
      }
    } on TimeoutException {
      throw _lost();
    }
    if (done == null) {
      // the stream ended without saying it finished: OpenAI says to count
      // only response.completed as a success
      throw _lost();
    }
    _busy = 0;

    final output = switch (done['output']) {
      final List list when list.isNotEmpty => list.cast<Map<String, dynamic>>(),
      _ => items,
    };
    return Message(
      Role.assistant,
      [
        for (final item in output)
          ...switch (item) {
            {'type': 'message', 'content': final List content} => [
              for (final part in content)
                if (part case {'type': 'output_text', 'text': final String t})
                  TextPart(t)
                else if (part case {'refusal': final String refusal})
                  TextPart(refusal),
            ],
            {'type': 'function_call', 'name': final String name} => [
              ToolCall(_bare(name), _args(item['arguments'])),
            ],
            _ => const <Part>[],
          },
      ],
      raw: output,
      usage: _usage(done['usage']),
    );
  }

  /// The chat as Responses API input items. A reply this provider wrote is
  /// sent back exactly as it came, reasoning included; a tool result goes
  /// with the call id of the call it answers.
  static List<Map<String, dynamic>> input(List<Message> messages) {
    final items = <Map<String, dynamic>>[];
    var calls = <String>[];
    var made = 0;
    for (final message in messages) {
      if (message.role == Role.assistant) {
        if (message.raw case final List raw) {
          final replay = raw.cast<Map<String, dynamic>>();
          items.addAll(replay);
          calls = [
            for (final item in replay)
              if (item case {
                'type': 'function_call',
                'call_id': final String id,
              })
                id,
          ];
          continue;
        }
        // written here, like a compacted summary: build the items
        calls = [];
        final text = [
          for (final part in message.parts)
            if (part case TextPart(:final text)) text,
        ].join('\n\n');
        if (text.isNotEmpty) {
          items.add({
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          });
        }
        for (final part in message.parts) {
          if (part case ToolCall(:final name, :final args)) {
            final id = 'call_harness_${made++}';
            calls.add(id);
            items.add({
              'type': 'function_call',
              'call_id': id,
              'name': name,
              'arguments': jsonEncode(args),
            });
          }
        }
        continue;
      }
      var answered = 0;
      final said = <String>[];
      for (final part in message.parts) {
        switch (part) {
          case ToolResult(:final output):
            items.add({
              'type': 'function_call_output',
              'call_id': answered < calls.length
                  ? calls[answered]
                  : 'call_harness_${made++}',
              'output': jsonEncode(output),
            });
            answered++;
          case TextPart(:final text) when text.isNotEmpty:
            said.add(text);
          default:
        }
      }
      if (said.isNotEmpty) {
        items.add({
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': said.join('\n\n')},
          ],
        });
      }
    }
    return items;
  }

  List<Map<String, dynamic>> _tools(List<Tool> tools) {
    final functions = [
      for (final tool in tools)
        {
          'type': 'function',
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
    ];
    if (!_namespaced) return functions;
    return [
      {
        'type': 'namespace',
        'name': _namespace,
        'description':
            "The coding harness's tools: files, commands, questions for the "
            'user, and other sessions.',
        'tools': functions,
      },
    ];
  }

  // A namespaced call may come back named "harness.readFile".
  static String _bare(String name) {
    for (final mark in ['.', '__', '/', ':']) {
      if (name.startsWith('$_namespace$mark')) {
        return name.substring(_namespace.length + mark.length);
      }
    }
    return name;
  }

  static Map<String, dynamic> _args(Object? arguments) {
    try {
      final args = jsonDecode('${arguments ?? '{}'}');
      return args is Map<String, dynamic> ? args : {};
    } on FormatException {
      return {};
    }
  }

  static Usage? _usage(Object? usage) {
    if (usage is! Map) return null;
    final cached = (usage['input_tokens_details'] as Map?)?['cached_tokens'];
    return Usage(
      input: (usage['input_tokens'] as num?)?.toInt() ?? 0,
      cached: (cached as num?)?.toInt() ?? 0,
      output: (usage['output_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  /// A guess: OpenAI's route for the ChatGPT plan has no token counter, so
  /// this is about four characters a token.
  @override
  Future<int> countTokens(List<Message> messages) async =>
      (jsonEncode(input(messages)).length / 4).ceil();

  // A request that went quiet: tried again after a wait that doubles.
  TryLater _lost() => TryLater(
    408,
    "no answer after ${timeout.inSeconds}s",
    retryAfter: _pause(Duration(seconds: min(5 << _busy++, 60))),
  );

  Duration _pause(Duration wait) {
    final until = _clock().add(wait);
    if (_pausedUntil == null || until.isAfter(_pausedUntil!)) {
      _pausedUntil = until;
    }
    return wait;
  }

  Never _fail(int status, String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      json = null;
    }
    final error = json is Map ? json['error'] : null;
    if (status == 401 && error is! Map) throw const _TryAgain.signIn();
    if (error is Map) {
      final param = '${error['param'] ?? ''}';
      if (error['code'] == 'subscription_sharing_unsupported_capability' &&
          param.startsWith('tools') &&
          _namespaced) {
        // this route wants the tools at the top level after all
        _namespaced = false;
        throw _TryAgain(status, '${error['message'] ?? 'tools'}');
      }
      _failCode(error['code'] as String?, error['message'], status);
    }
    _failCode(null, json is Map ? json['detail'] : _message(body), status);
  }

  // What each of OpenAI's errors for this route means for the user.
  Never _failCode(String? code, Object? message, int status) {
    final text = '${message ?? 'no message'}'.split('\n').first;
    switch (code) {
      case 'subscription_sharing_usage_limit_exceeded':
        throw ProviderError(
          429,
          "your ChatGPT plan's usage limit is reached. See $chatGptUsageUrl",
        );
      case 'subscription_sharing_user_not_eligible':
        throw const ProviderError(
          403,
          "this ChatGPT account can't use its plan in other apps (it needs "
          'Plus or Pro)',
        );
      case 'subscription_sharing_invalid_user':
        throw const ProviderError(
          401,
          'sign in with ChatGPT again: run it with --chatgpt',
        );
      case 'subscription_sharing_usage_unavailable' ||
          'subscription_sharing_user_unavailable':
        throw TryLater(
          503,
          text,
          retryAfter: _pause(Duration(seconds: min(5 << _busy++, 60))),
        );
    }
    if (status == 401) throw const _TryAgain.signIn();
    if (status == 429) {
      throw RateLimited(
        text,
        retryAfter: _pause(Duration(seconds: min(10 << _busy++, 60))),
      );
    }
    if (status >= 500) {
      throw TryLater(
        status,
        text,
        retryAfter: _pause(Duration(seconds: min(5 << _busy++, 60))),
      );
    }
    throw ProviderError(status, code == null ? text : '$code: $text');
  }

  // Server-sent events: each one's data, as JSON. Built from transformers,
  // not an async* function, so cancelling it when the answer goes quiet
  // stops it at once.
  static Stream<Map<String, dynamic>> _events(Stream<List<int>> bytes) {
    final data = StringBuffer();
    Map<String, dynamic>? event() {
      if (data.isEmpty) return null;
      final text = data.toString();
      data.clear();
      try {
        if (jsonDecode(text) case final Map<String, dynamic> event) {
          return event;
        }
      } on FormatException {
        // [DONE], or not an event
      }
      return null;
    }

    return bytes
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .transform(
          StreamTransformer<String, Map<String, dynamic>>.fromHandlers(
            handleData: (line, sink) {
              if (line.isEmpty) {
                if (event() case final e?) sink.add(e);
              } else if (line.startsWith('data:')) {
                if (data.isNotEmpty) data.write('\n');
                data.write(line.substring(5).trimLeft());
              }
            },
            handleDone: (sink) {
              if (event() case final e?) sink.add(e);
              sink.close();
            },
          ),
        );
  }

  static String _message(String body) {
    try {
      final json = jsonDecode(body);
      if (json case {'error': {'message': final String message}}) {
        return message.split('\n').first;
      }
      if (json case {'detail': final String detail}) return detail;
    } on FormatException {
      // not JSON
    }
    final text = body.trim();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}

// The request can go again at once: with a fresh token after a 401, or
// with the tools laid out the other way.
class _TryAgain implements Exception {
  const _TryAgain(this.status, this.message) : refresh = false;

  // ChatGPT turned the token down: refresh it and try once more
  const _TryAgain.signIn()
    : status = 401,
      message =
          "ChatGPT didn't take the sign-in. Run it with --chatgpt to "
          'sign in again.',
      refresh = true;

  final int status;
  final String message;
  final bool refresh;
}
