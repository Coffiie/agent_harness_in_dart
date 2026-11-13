import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coding_agent_in_dart/src/chatgpt_auth.dart';
import 'package:coding_agent_in_dart/src/chatgpt_provider.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const issued = 'oaiapp_test';
final now = DateTime.utc(2026, 11, 13, 12);

String jwt(Map<String, Object?> claims) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part(claims)}.c2lnbmF0dXJl';
}

Map<String, Object?> tokens({
  String? nonce,
  String access = 'access-1',
  String? refresh = 'refresh-1',
  String scope = ChatGptAuth.scopes,
  String audience = issued,
}) => {
  'id_token': jwt({
    'iss': ChatGptAuth.issuer,
    'aud': audience,
    'sub': 'user-1',
    'email': 'someone@example.com',
    'nonce': ?nonce,
  }),
  'access_token': access,
  'refresh_token': ?refresh,
  'expires_in': 3600,
  'scope': scope,
};

ChatGptAccount account({DateTime? expires}) => ChatGptAccount(
  clientId: issued,
  subject: 'user-1',
  email: 'someone@example.com',
  idToken: jwt({'iss': ChatGptAuth.issuer, 'aud': issued}),
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  expiresAt: expires ?? now.add(const Duration(hours: 1)),
  scopes: ChatGptAuth.scopes.split(' '),
);

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('chatgpt_test');
    file = File('${dir.path}/chatgpt.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> savedAccount({DateTime? expires}) async {
    final auth = ChatGptAuth(file, clock: () => now)
      ..account = account(expires: expires);
    await auth.save();
  }

  group('signing in', () {
    // Plays the browser: checks the address the harness opened, then comes
    // back to its callback the way OpenAI's sign-in would.
    Future<void> Function(Uri) browser(
      List<Uri> opened, {
      Map<String, String> Function(Uri url)? back,
      bool strangerFirst = false,
    }) => (url) async {
      opened.add(url);
      final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
      final client = http.Client();
      try {
        if (strangerFirst) {
          // another attempt's callback is ignored
          await client.get(
            redirect.replace(queryParameters: {'state': 'x', 'code': 'x'}),
          );
        }
        await client.get(
          redirect.replace(
            queryParameters:
                back?.call(url) ??
                {
                  'code': 'code-1',
                  'state': url.queryParameters['state']!,
                  'client_id': issued,
                },
          ),
        );
      } finally {
        client.close();
      }
    };

    test(
      'opens the browser, takes the callback, and keeps the tokens',
      () async {
        final opened = <Uri>[];
        Map<String, String>? form;
        final auth = ChatGptAuth(
          file,
          port: 0,
          clock: () => now,
          openBrowser: browser(opened, strangerFirst: true),
          client: MockClient((request) async {
            expect(request.url, ChatGptAuth.tokenUrl);
            form = Uri.splitQueryString(request.body);
            return http.Response(
              jsonEncode(tokens(nonce: opened.single.queryParameters['nonce'])),
              200,
            );
          }),
        );

        final signedIn = await auth.signIn();

        final query = opened.single.queryParameters;
        expect(opened.single.path, '/api/accounts/authorize');
        expect(query['client_id'], 'dynamic_agent_client');
        expect(query['agent_name_hint'], 'coding_agent_in_dart');
        expect(query['ext_agent_host_id'], startsWith('urn:uuid:'));
        expect(query['scope'], contains('chatgpt.tokens.use.direct'));
        expect(query['resource'], 'https://api.openai.com/v1');
        expect(query['code_challenge_method'], 'S256');
        expect(Uri.parse(query['redirect_uri']!).host, '127.0.0.1');

        expect(form!['grant_type'], 'authorization_code');
        expect(form!['client_id'], issued);
        expect(form!['code'], 'code-1');
        // the verifier matches the challenge the browser got
        final challenge = base64Url
            .encode(sha256.convert(ascii.encode(form!['code_verifier']!)).bytes)
            .replaceAll('=', '');
        expect(challenge, query['code_challenge']);

        expect(signedIn.email, 'someone@example.com');
        expect(signedIn.accessToken, 'access-1');
        final saved = jsonDecode(file.readAsStringSync());
        expect(saved['client_id'], issued);
        expect(saved['host_id'], query['ext_agent_host_id']);
        expect(saved['account']['refresh_token'], 'refresh-1');
        if (!Platform.isWindows) {
          expect(file.statSync().modeString(), 'rw-------');
        }
      },
    );

    test('a second sign-in uses the issued client id and says who', () async {
      await savedAccount();
      final opened = <Uri>[];
      final auth = ChatGptAuth(
        file,
        port: 0,
        clock: () => now,
        openBrowser: browser(
          opened,
          back: (url) => {'code': 'c', 'state': url.queryParameters['state']!},
        ),
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(tokens(nonce: opened.single.queryParameters['nonce'])),
            200,
          ),
        ),
      );
      final hostId = auth.hostId;

      await auth.signIn();

      final query = opened.single.queryParameters;
      expect(query['client_id'], issued);
      expect(query.containsKey('agent_name_hint'), isFalse);
      expect(query['login_hint'], 'someone@example.com');
      expect(query['id_token_hint'], isNotNull);
      expect(query['ext_agent_host_id'], hostId);
    });

    test('says so when the user cancels', () async {
      final auth = ChatGptAuth(
        file,
        port: 0,
        openBrowser: browser(
          [],
          back: (url) => {
            'error': 'access_denied',
            'state': url.queryParameters['state']!,
          },
        ),
        client: MockClient((_) async => fail('no token request')),
      );
      await expectLater(
        auth.signIn(),
        throwsA(
          isA<SignInError>().having(
            (e) => e.message,
            'message',
            'You cancelled the sign-in.',
          ),
        ),
      );
      expect(auth.signedIn, isFalse);
    });

    test(
      'refuses tokens without the plan scope, or for someone else',
      () async {
        for (final (bad, said) in [
          (
            (String n) => tokens(nonce: n, scope: 'openid email'),
            "didn't let the harness use your ChatGPT plan",
          ),
          ((String n) => tokens(nonce: 'other'), "doesn't match this sign-in"),
          (
            (String n) => tokens(nonce: n, audience: 'someone-else'),
            "isn't for this sign-in",
          ),
        ]) {
          final opened = <Uri>[];
          final auth = ChatGptAuth(
            file,
            port: 0,
            clock: () => now,
            openBrowser: browser(opened),
            client: MockClient(
              (_) async => http.Response(
                jsonEncode(bad(opened.single.queryParameters['nonce']!)),
                200,
              ),
            ),
          );
          await expectLater(
            auth.signIn(),
            throwsA(
              isA<SignInError>().having(
                (e) => e.message,
                'message',
                contains(said),
              ),
            ),
          );
          expect(auth.signedIn, isFalse);
        }
      },
    );
  });

  group('tokens', () {
    test(
      'refresh when about to run out, one refresh for many requests',
      () async {
        await savedAccount(expires: now.add(const Duration(seconds: 30)));
        var refreshes = 0;
        final auth = ChatGptAuth(
          file,
          clock: () => now,
          client: MockClient((request) async {
            final form = Uri.splitQueryString(request.body);
            expect(form['grant_type'], 'refresh_token');
            expect(form['refresh_token'], 'refresh-1');
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return http.Response(
              jsonEncode(tokens(access: 'access-2', refresh: 'refresh-2')),
              200,
            );
          }),
        );

        final got = await Future.wait([
          auth.accessToken(),
          auth.accessToken(),
          auth.accessToken(),
        ]);

        expect(got, everyElement('access-2'));
        expect(refreshes, 1);
        expect(
          jsonDecode(file.readAsStringSync())['account']['refresh_token'],
          'refresh-2',
        );
        // fresh now
        expect(await auth.accessToken(), 'access-2');
        expect(refreshes, 1);
      },
    );

    test('a spent refresh token signs out', () async {
      await savedAccount(expires: now.subtract(const Duration(minutes: 1)));
      final auth = ChatGptAuth(
        file,
        clock: () => now,
        client: MockClient(
          (_) async => http.Response('{"error":"invalid_grant"}', 400),
        ),
      );
      await expectLater(auth.accessToken(), throwsA(isA<SignInError>()));
      expect(auth.signedIn, isFalse);
      expect(ChatGptAuth(file).signedIn, isFalse);
    });

    test('signing out revokes the refresh token and keeps the ids', () async {
      await savedAccount();
      final revoked = <String, String>{};
      final auth = ChatGptAuth(
        file,
        client: MockClient((request) async {
          if (request.url == ChatGptAuth.discoveryUrl) {
            return http.Response(
              '{"revocation_endpoint":"https://auth.openai.com/oauth/revoke"}',
              200,
            );
          }
          expect(request.url.path, '/oauth/revoke');
          revoked.addAll(Uri.splitQueryString(request.body));
          return http.Response('', 200);
        }),
      );
      final hostId = auth.hostId;

      await auth.signOut();

      expect(revoked['token'], 'refresh-1');
      expect(revoked['token_type_hint'], 'refresh_token');
      expect(auth.signedIn, isFalse);
      final saved = jsonDecode(file.readAsStringSync());
      expect(saved['account'], isNull);
      expect(saved['client_id'], issued);
      expect(saved['host_id'], hostId);
    });
  });

  group('the provider', () {
    late ChatGptAuth auth;
    final requests = <Map<String, dynamic>>[];
    final waits = <Duration>[];
    var tokenRequests = 0;

    setUp(() async {
      requests.clear();
      waits.clear();
      tokenRequests = 0;
      await savedAccount();
    });

    String sse(List<Map<String, Object?>> events) => [
      for (final e in events) 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n',
    ].join();

    Map<String, Object?> done(
      List<Map<String, Object?>> output, {
      Map<String, Object?>? usage,
    }) => {
      'type': 'response.completed',
      'response': {'output': output, 'usage': ?usage},
    };

    Map<String, Object?> said(String text) => {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text},
      ],
    };

    // Answers each POST to /responses with the next of [answers]: an SSE
    // body, or (status, JSON) for an error.
    ChatGptProvider provider(
      List<Object> answers, {
      Duration timeout = const Duration(seconds: 90),
    }) {
      final client = MockClient.streaming((request, body) async {
        if (request.url == ChatGptAuth.tokenUrl) {
          tokenRequests++;
          await body.drain<void>();
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(tokens(access: 'access-2')))),
            200,
          );
        }
        expect(request.url.toString(), 'https://api.openai.com/v1/responses');
        requests.add({
          ...jsonDecode(await body.bytesToString()) as Map<String, dynamic>,
          '_auth': request.headers['Authorization'],
        });
        final answer = answers.removeAt(0);
        return switch (answer) {
          final String events => http.StreamedResponse(
            Stream.value(utf8.encode(events)),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
          (final int status, final Object json) => http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(json))),
            status,
          ),
          final Stream<List<int>> stream => http.StreamedResponse(stream, 200),
          _ => throw StateError('$answer'),
        };
      });
      auth = ChatGptAuth(file, client: client, clock: () => now);
      return ChatGptProvider(
        auth,
        model: 'gpt-test',
        client: client,
        clock: () => now,
        sleep: (d) async => waits.add(d),
        timeout: timeout,
      );
    }

    final readFile = Tool(
      name: 'readFile',
      description: 'Read a file',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      },
      label: (args) => 'ReadFile',
      run: (args) async => {},
    );

    test(
      'sends the chat, the instructions and the tools, and reads the reply',
      () async {
        final chatgpt = provider([
          sse([
            {'type': 'response.output_item.done', 'item': said('Hello.')},
            done(
              [said('Hello.')],
              usage: {
                'input_tokens': 120,
                'input_tokens_details': {'cached_tokens': 100},
                'output_tokens': 7,
              },
            ),
          ]),
        ]);

        final reply = await chatgpt.generate(
          [
            const Message(Role.user, [TextPart('hi')]),
          ],
          tools: [readFile],
          system: 'You are a coding agent.',
        );

        final sent = requests.single;
        expect(sent['_auth'], 'Bearer access-1');
        expect(sent['model'], 'gpt-test');
        expect(sent['store'], false);
        expect(sent['stream'], true);
        expect(sent['instructions'], 'You are a coding agent.');
        expect(sent['input'], [
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'hi'},
            ],
          },
        ]);
        final namespace = (sent['tools'] as List).single as Map;
        expect(namespace['type'], 'namespace');
        expect(namespace['name'], 'harness');
        expect((namespace['tools'] as List).single['name'], 'readFile');

        expect((reply.parts.single as TextPart).text, 'Hello.');
        expect(reply.usage!.input, 120);
        expect(reply.usage!.cached, 100);
        expect(reply.usage!.output, 7);
      },
    );

    test(
      'a tool call comes back by name, and its result goes with its call id',
      () async {
        final call = {
          'type': 'function_call',
          'id': 'fc_1',
          'call_id': 'call_1',
          'name': 'harness.readFile',
          'arguments': '{"path":"lib/a.dart"}',
        };
        const reasoning = {
          'type': 'reasoning',
          'id': 'rs_1',
          'encrypted_content': 'abc',
          'summary': <Object>[],
        };
        final chatgpt = provider([
          sse([
            done([reasoning, call]),
          ]),
          sse([
            done([said('It has one class.')]),
          ]),
        ]);
        final chat = [
          const Message(Role.user, [TextPart('read lib/a.dart')]),
        ];

        final first = await chatgpt.generate(chat, tools: [readFile]);
        final asked = first.parts.single as ToolCall;
        expect(asked.name, 'readFile');
        expect(asked.args, {'path': 'lib/a.dart'});

        chat
          ..add(first)
          ..add(
            const Message(Role.user, [
              ToolResult('readFile', {'contents': 'class A {}'}),
            ]),
          );
        await chatgpt.generate(chat, tools: [readFile]);

        // the reply goes back exactly as it came, reasoning included
        expect((requests.last['input'] as List).skip(1), [
          reasoning,
          call,
          {
            'type': 'function_call_output',
            'call_id': 'call_1',
            'output': '{"contents":"class A {}"}',
          },
        ]);
      },
    );

    test('a reply written here, like a summary, becomes input items', () {
      final items = ChatGptProvider.input([
        const Message(Role.assistant, [
          TextPart('Summary so far.'),
          ToolCall('listFiles', {'path': '.'}),
        ]),
        const Message(Role.user, [
          ToolResult('listFiles', {'files': <String>[]}),
          TextPart('and then?'),
        ]),
      ]);
      expect(items[0]['role'], 'assistant');
      expect(items[1]['type'], 'function_call');
      expect(items[2]['call_id'], items[1]['call_id']);
      expect(items[3]['content'], [
        {'type': 'input_text', 'text': 'and then?'},
      ]);
    });

    test(
      "sends the tools at the top level when the namespace isn't taken",
      () async {
        final chatgpt = provider([
          (
            400,
            {
              'error': {
                'code': 'subscription_sharing_unsupported_capability',
                'param': 'tools[0]',
                'message': 'namespace tools are not supported',
              },
            },
          ),
          sse([
            done([said('ok')]),
          ]),
          sse([
            done([said('ok')]),
          ]),
        ]);
        final chat = [
          const Message(Role.user, [TextPart('hi')]),
        ];

        await chatgpt.generate(chat, tools: [readFile]);
        await chatgpt.generate(chat, tools: [readFile]);

        expect(requests[0]['tools'][0]['type'], 'namespace');
        expect(requests[1]['tools'][0]['type'], 'function');
        expect(requests[2]['tools'][0]['type'], 'function');
        expect(tokenRequests, 0);
      },
    );

    test(
      'the plan running out is said plainly, with where to see it',
      () async {
        final chatgpt = provider([
          (
            429,
            {
              'error': {
                'code': 'subscription_sharing_usage_limit_exceeded',
                'message': 'limit',
              },
            },
          ),
        ]);
        await expectLater(
          chatgpt.generate([
            const Message(Role.user, [TextPart('hi')]),
          ]),
          throwsA(
            isA<ProviderError>()
                .having((e) => e is TryLater, 'tries later', isFalse)
                .having(
                  (e) => e.message,
                  'message',
                  contains('chatgpt.com/settings/usage'),
                ),
          ),
        );
      },
    );

    test('an account without Plus or Pro is told so', () async {
      final chatgpt = provider([
        (
          403,
          {
            'error': {
              'code': 'subscription_sharing_user_not_eligible',
              'message': 'no',
            },
          },
        ),
      ]);
      await expectLater(
        chatgpt.generate([
          const Message(Role.user, [TextPart('hi')]),
        ]),
        throwsA(
          isA<ProviderError>().having(
            (e) => e.message,
            'message',
            contains('Plus or Pro'),
          ),
        ),
      );
    });

    test('a busy ChatGPT is tried later, and holds the next request', () async {
      final chatgpt = provider([
        (
          503,
          {
            'error': {'message': 'overloaded'},
          },
        ),
        sse([
          done([said('ok')]),
        ]),
      ]);
      final chat = [
        const Message(Role.user, [TextPart('hi')]),
      ];

      await expectLater(
        chatgpt.generate(chat),
        throwsA(
          isA<TryLater>()
              .having((e) => e.status, 'status', 503)
              .having((e) => e.retryAfter, 'wait', const Duration(seconds: 5)),
        ),
      );
      await chatgpt.generate(chat);
      expect(waits, [const Duration(seconds: 5)]);
    });

    test(
      'a token turned down is refreshed once, then the request goes again',
      () async {
        final chatgpt = provider([
          (
            401,
            {
              'error': {'message': 'expired'},
            },
          ),
          sse([
            done([said('ok')]),
          ]),
        ]);
        await chatgpt.generate([
          const Message(Role.user, [TextPart('hi')]),
        ]);
        expect(tokenRequests, 1);
        expect(requests.map((r) => r['_auth']), [
          'Bearer access-1',
          'Bearer access-2',
        ]);
      },
    );

    test(
      'an answer that stops without finishing, or goes quiet, is tried later',
      () async {
        final quiet = StreamController<List<int>>();
        final chatgpt = provider([
          sse([
            {'type': 'response.output_item.done', 'item': said('Hel')},
          ]),
          quiet.stream,
        ], timeout: const Duration(milliseconds: 50));
        final chat = [
          const Message(Role.user, [TextPart('hi')]),
        ];

        for (var i = 0; i < 2; i++) {
          await expectLater(
            chatgpt.generate(chat),
            throwsA(isA<TryLater>().having((e) => e.status, 'status', 408)),
          );
        }
        unawaited(quiet.close());
      },
    );

    test('lists the models the account can pick', () async {
      await savedAccount();
      final models = await ChatGptProvider.models(
        ChatGptAuth(file, clock: () => now),
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://api.openai.com/v1/models');
          expect(request.headers['Authorization'], 'Bearer access-1');
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'slug': 'gpt-a',
                  'display_name': 'GPT A',
                  'visibility': 'list',
                },
                {'slug': 'gpt-hidden', 'visibility': 'hide'},
                {'slug': 'gpt-b', 'visibility': 'list'},
              ],
            }),
            200,
          );
        }),
      );
      expect(
        [for (final m in models) '${m.slug} ${m.name}'],
        ['gpt-a GPT A', 'gpt-b gpt-b'],
      );
    });

    test('guesses tokens at about four characters each', () async {
      final chatgpt = provider([]);
      final count = await chatgpt.countTokens([
        Message(Role.user, [TextPart('a' * 400)]),
      ]);
      expect(count, inInclusiveRange(100, 130));
    });
  });
}
