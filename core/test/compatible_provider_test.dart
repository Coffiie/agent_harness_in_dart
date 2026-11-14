import 'dart:convert';
import 'dart:io';

import 'package:coding_agent_core/src/compatible_provider.dart';
import 'package:coding_agent_core/src/messages.dart';
import 'package:coding_agent_core/src/model_provider.dart';
import 'package:coding_agent_core/src/tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final readFile = Tool(
  name: 'readFile',
  description: 'Read a file',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {'type': 'string'},
    },
  },
  label: (_) => '',
  run: (_) async => {},
);

http.Response reply(Map<String, Object?> message, {Object? usage}) =>
    http.Response(
      jsonEncode({
        'choices': [
          {'message': message},
        ],
        'usage': ?usage,
      }),
      200,
    );

void main() {
  test('every provider has an id, and --provider finds it', () {
    expect(Endpoint.all.map((e) => e.id), [
      'deepseek',
      'kimi',
      'groq',
      'openrouter',
      'ollama',
    ]);
    expect(Endpoint.named('DeepSeek'), Endpoint.deepSeek);
    expect(Endpoint.named('nope'), isNull);
    // only the one on this computer goes without a key
    expect(Endpoint.all.where((e) => e.keyVariable == null), [Endpoint.ollama]);
  });

  test(
    'sends the instructions, the chat and the tools, and reads the reply',
    () async {
      late http.Request sent;
      final provider = CompatibleProvider(
        Endpoint.deepSeek,
        model: 'deepseek-flash',
        apiKey: 'key-1',
        client: MockClient((request) async {
          sent = request;
          return reply(
            {'role': 'assistant', 'content': 'Hello.'},
            usage: {
              'prompt_tokens': 120,
              'prompt_cache_hit_tokens': 100,
              'completion_tokens': 7,
            },
          );
        }),
      );

      final message = await provider.generate(
        [
          const Message(Role.user, [TextPart('hi')]),
        ],
        tools: [readFile],
        system: 'Be brief.',
      );

      expect(sent.url.toString(), 'https://api.deepseek.com/chat/completions');
      expect(sent.headers['Authorization'], 'Bearer key-1');
      final body = jsonDecode(sent.body);
      expect(body['model'], 'deepseek-flash');
      expect(body['messages'], [
        {'role': 'system', 'content': 'Be brief.'},
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(body['tools'], [
        {
          'type': 'function',
          'function': {
            'name': 'readFile',
            'description': 'Read a file',
            'parameters': readFile.parameters,
          },
        },
      ]);
      expect((message.parts.single as TextPart).text, 'Hello.');
      expect(
        (message.usage!.input, message.usage!.cached, message.usage!.output),
        (120, 100, 7),
      );
      expect(provider.name, 'DeepSeek');
    },
  );

  test(
    'Ollama takes no key, and its cache count is read the OpenAI way',
    () async {
      late http.Request sent;
      final provider = CompatibleProvider(
        Endpoint.ollama,
        model: 'gpt-oss:20b',
        client: MockClient((request) async {
          sent = request;
          return reply(
            {'role': 'assistant', 'content': 'ok'},
            usage: {
              'prompt_tokens': 50,
              'prompt_tokens_details': {'cached_tokens': 20},
              'completion_tokens': 2,
            },
          );
        }),
      );
      final message = await provider.generate([
        const Message(Role.user, [TextPart('hi')]),
      ]);
      expect(sent.url.toString(), 'http://localhost:11434/v1/chat/completions');
      expect(sent.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(sent.body).containsKey('tools'), isFalse);
      expect(message.usage!.cached, 20);
      expect(provider.timeout, const Duration(minutes: 5));
    },
  );

  test(
    'a tool call comes back by name, and its result goes with its id',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final provider = CompatibleProvider(
        Endpoint.groq,
        model: 'openai/gpt-oss-120b',
        apiKey: 'k',
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return reply({
            'role': 'assistant',
            'content': null,
            'reasoning_content': 'I should read it.',
            'tool_calls': [
              {
                'id': 'call_9',
                'type': 'function',
                'function': {
                  'name': 'readFile',
                  'arguments': '{"path":"a.txt"}',
                },
              },
              {
                'id': 'call_10',
                'type': 'function',
                'function': {'name': 'readFile', 'arguments': 'not json'},
              },
            ],
          });
        }),
      );

      final first = await provider.generate(
        [
          const Message(Role.user, [TextPart('read a.txt and b.txt')]),
        ],
        tools: [readFile],
      );
      final calls = first.parts.cast<ToolCall>();
      expect(calls.map((c) => c.name), ['readFile', 'readFile']);
      expect(calls.first.args, {'path': 'a.txt'});
      // arguments that aren't JSON become no arguments
      expect(calls.last.args, isEmpty);

      await provider.generate(
        [
          const Message(Role.user, [TextPart('read a.txt and b.txt')]),
          first,
          const Message(Role.user, [
            ToolResult('readFile', {'content': 'A'}),
            ToolResult('readFile', {'error': 'no b.txt'}),
          ]),
        ],
        tools: [readFile],
      );

      final chat = bodies.last['messages'] as List;
      // the reply goes back as it came, DeepSeek's thinking included
      expect(chat[1], {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_9',
            'type': 'function',
            'function': {'name': 'readFile', 'arguments': '{"path":"a.txt"}'},
          },
          {
            'id': 'call_10',
            'type': 'function',
            'function': {'name': 'readFile', 'arguments': 'not json'},
          },
        ],
        'reasoning_content': 'I should read it.',
      });
      expect(chat.sublist(2), [
        {
          'role': 'tool',
          'tool_call_id': 'call_9',
          'content': '{"content":"A"}',
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_10',
          'content': '{"error":"no b.txt"}',
        },
      ]);
    },
  );

  test('a reply written here, like a summary, gets ids of its own', () {
    final chat = CompatibleProvider.chat([
      const Message(Role.assistant, [
        TextPart('Summary so far.'),
        ToolCall('readFile', {'path': 'x'}),
      ]),
      const Message(Role.user, [
        ToolResult('readFile', {'content': 'X'}),
        TextPart('go on'),
      ]),
    ]);
    expect(chat, [
      {
        'role': 'assistant',
        'content': 'Summary so far.',
        'tool_calls': [
          {
            'id': 'call_harness_0',
            'type': 'function',
            'function': {'name': 'readFile', 'arguments': '{"path":"x"}'},
          },
        ],
      },
      {
        'role': 'tool',
        'tool_call_id': 'call_harness_0',
        'content': '{"content":"X"}',
      },
      {'role': 'user', 'content': 'go on'},
    ]);
  });

  group('errors', () {
    Future<Object> failure(
      Endpoint endpoint,
      http.Response response, {
      DateTime Function()? clock,
    }) async {
      try {
        await CompatibleProvider(
          endpoint,
          model: 'm',
          apiKey: 'k',
          clock: clock,
          client: MockClient((_) async => response),
        ).generate([
          const Message(Role.user, [TextPart('hi')]),
        ]);
      } catch (e) {
        return e;
      }
      fail('no error');
    }

    test('a key turned down names the variable it came from', () async {
      final e = await failure(
        Endpoint.groq,
        http.Response('{"error":{"message":"Invalid API Key"}}', 401),
      );
      expect(
        '$e',
        '401: Groq turned down the key in GROQ_API_KEY: Invalid API Key',
      );
    });

    test('an empty DeepSeek balance says to top up', () async {
      final e = await failure(
        Endpoint.deepSeek,
        http.Response('{"error":{"message":"Insufficient Balance"}}', 402),
      );
      expect(
        '$e',
        '402: Your DeepSeek balance has run out: Insufficient Balance. Top it '
            'up, then try again.',
      );
    });

    test('a model Ollama lacks says how to pull it', () async {
      final e = await failure(
        Endpoint.ollama,
        http.Response('{"error":{"message":"model \\"m\\" not found"}}', 404),
      );
      expect('$e', "404: Ollama doesn't have m. Pull it with `ollama pull m`.");
    });

    test(
      'a rate limit waits as long as the endpoint asks, for every session',
      () async {
        final now = DateTime(2026, 11, 14, 12);
        final e = await failure(
          Endpoint.openRouter,
          http.Response(
            '{"error":{"message":"Rate limit exceeded: free-models-per-min"}}',
            429,
            headers: {'retry-after': '7'},
          ),
          clock: () => now,
        );
        expect(
          e,
          isA<RateLimited>()
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              )
              .having((e) => e.message, 'message', contains('free-models')),
        );
      },
    );

    test(
      'a busy endpoint is tried later, and holds the next request',
      () async {
        var now = DateTime(2026, 11, 14, 12);
        final slept = <Duration>[];
        var calls = 0;
        final provider = CompatibleProvider(
          Endpoint.kimi,
          model: 'kimi-k2.7-code',
          apiKey: 'k',
          clock: () => now,
          sleep: (d) async {
            slept.add(d);
            now = now.add(d);
          },
          client: MockClient((_) async {
            if (calls++ == 0) {
              return http.Response('{"error":{"message":"overloaded"}}', 503);
            }
            return reply({'role': 'assistant', 'content': 'back'});
          }),
        );
        final chat = [
          const Message(Role.user, [TextPart('hi')]),
        ];
        await expectLater(
          provider.generate(chat),
          throwsA(
            isA<TryLater>().having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 5),
            ),
          ),
        );
        final message = await provider.generate(chat);
        expect(slept, [const Duration(seconds: 5)]);
        expect((message.parts.single as TextPart).text, 'back');
      },
    );

    test('Ollama not running says how to start it', () async {
      final provider = CompatibleProvider(
        Endpoint.ollama,
        model: 'm',
        client: MockClient(
          (_) async => throw const SocketException('Connection refused'),
        ),
      );
      await expectLater(
        provider.generate([
          const Message(Role.user, [TextPart('hi')]),
        ]),
        throwsA(
          isA<ProviderError>().having(
            (e) => e.message,
            'message',
            "Can't reach Ollama at localhost:11434. Open the Ollama app, or "
                'run `ollama serve`.',
          ),
        ),
      );
    });
  });

  test('lists the models an endpoint has', () async {
    late http.Request sent;
    final models = await CompatibleProvider.models(
      Endpoint.ollama,
      client: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'gpt-oss:20b', 'object': 'model'},
              {'id': 'qwen3:8b', 'object': 'model'},
            ],
          }),
          200,
        );
      }),
    );
    expect(sent.url.toString(), 'http://localhost:11434/v1/models');
    expect(models, ['gpt-oss:20b', 'qwen3:8b']);
  });

  test('guesses tokens at about four characters each', () async {
    final provider = CompatibleProvider(Endpoint.ollama, model: 'm');
    final count = await provider.countTokens([
      Message(Role.user, [TextPart('x' * 400)]),
    ]);
    expect(count, closeTo(110, 10));
  });
}
