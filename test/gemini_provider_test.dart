import 'dart:async';
import 'dart:convert';

import 'package:coding_agent_in_dart/src/events.dart';
import 'package:coding_agent_in_dart/src/gemini_provider.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const url = 'https://generativelanguage.googleapis.com/v1beta/models';
const hello = Message(Role.user, [TextPart('hello')]);

void main() {
  late http.Response response;
  late List<http.Request> requests;
  late GeminiProvider gemini;

  void respond(Object body) => response = http.Response(jsonEncode(body), 200);

  Map<String, dynamic> reply(List<Map<String, dynamic>> parts) => {
    'candidates': [
      {
        'content': {'role': 'model', 'parts': parts},
      },
    ],
  };

  setUp(() {
    requests = [];
    gemini = GeminiProvider(
      'key',
      client: MockClient((request) async {
        requests.add(request);
        return response;
      }),
    );
  });

  test('sends the conversation and tools to generateContent', () async {
    respond(
      reply([
        {'text': 'hi'},
      ]),
    );

    await gemini.generate([
      hello,
      const Message(Role.assistant, [
        TextPart('reading'),
        ToolCall('readFile', {'path': 'a.txt'}),
      ]),
      const Message(Role.user, [
        ToolResult('readFile', {'content': 'x'}),
      ]),
    ], tools: fileTools());

    final request = requests.single;
    expect(
      request.url.toString(),
      '$url/gemini-3.1-flash-lite:generateContent',
    );
    expect(request.headers['x-goog-api-key'], 'key');
    final body = jsonDecode(request.body);
    expect(body['contents'], [
      {
        'role': 'user',
        'parts': [
          {'text': 'hello'},
        ],
      },
      {
        'role': 'model',
        'parts': [
          {'text': 'reading'},
          {
            'functionCall': {
              'name': 'readFile',
              'args': {'path': 'a.txt'},
            },
          },
        ],
      },
      {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'readFile',
              'response': {'content': 'x'},
            },
          },
        ],
      },
    ]);
    expect(body['tools'][0]['functionDeclarations'][0], {
      'name': 'readFile',
      'description': 'Read the contents of a file from a given path',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'path': {'type': 'STRING', 'description': 'the path of the file'},
        },
        'required': ['path'],
      },
    });
  });

  test('sends the system prompt as systemInstruction', () async {
    respond(
      reply([
        {'text': 'hi'},
      ]),
    );

    await gemini.generate([hello], system: 'be brief');
    await gemini.generate([hello]);

    expect(jsonDecode(requests.first.body)['systemInstruction'], {
      'parts': [
        {'text': 'be brief'},
      ],
    });
    expect(
      jsonDecode(requests.last.body),
      isNot(contains('systemInstruction')),
    );
  });

  test('reads text and function calls from the reply', () async {
    respond(
      reply([
        {'text': 'reading'},
        {
          'functionCall': {
            'name': 'readFile',
            'args': {'path': 'a.txt'},
          },
        },
        {
          'functionCall': {'name': 'listFiles'},
        },
      ]),
    );

    final message = await gemini.generate([hello]);

    expect(message.role, Role.assistant);
    final [text as TextPart, read as ToolCall, list as ToolCall] =
        message.parts;
    expect(text.text, 'reading');
    expect(read.name, 'readFile');
    expect(read.args, {'path': 'a.txt'});
    expect(list.name, 'listFiles');
    expect(list.args, isEmpty);
  });

  test('sends its own replies back as is, thoughtSignature included', () async {
    final content = {
      'role': 'model',
      'parts': [
        {
          'functionCall': {'name': 'listFiles', 'args': {}},
          'thoughtSignature': 'sig',
        },
      ],
    };
    respond({
      'candidates': [
        {'content': content},
      ],
    });

    final message = await gemini.generate([hello]);
    await gemini.generate([hello, message]);

    expect(jsonDecode(requests.last.body)['contents'][1], content);
  });

  test('reads the usage, counting thinking as output', () async {
    respond({
      ...reply([
        {'text': 'hi'},
      ]),
      'usageMetadata': {
        'promptTokenCount': 1200,
        'cachedContentTokenCount': 1000,
        'candidatesTokenCount': 30,
        'thoughtsTokenCount': 70,
        'totalTokenCount': 1300,
      },
    });

    final usage = (await gemini.generate([hello])).usage!;

    expect((usage.input, usage.cached, usage.output), (1200, 1000, 100));
  });

  test('has no usage when Gemini sends none', () async {
    respond(
      reply([
        {'text': 'hi'},
      ]),
    );

    expect((await gemini.generate([hello])).usage, isNull);
  });

  test('counts tokens', () async {
    respond({'totalTokens': 42});

    expect(await gemini.countTokens([hello]), 42);
    expect(
      requests.single.url.toString(),
      '$url/gemini-3.1-flash-lite:countTokens',
    );
    expect(jsonDecode(requests.single.body), {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': 'hello'},
          ],
        },
      ],
    });
  });

  test('throws when the request fails', () {
    response = http.Response('bad key', 403);

    expect(
      gemini.generate([hello]),
      throwsA(predicate((e) => e is ProviderError && '$e' == '403: bad key')),
    );
  });

  test("keeps only the error's message from Gemini's JSON", () {
    response = http.Response(
      jsonEncode({
        'error': {
          'code': 503,
          'message': 'The model is overloaded. Please try again later.',
          'status': 'UNAVAILABLE',
        },
      }),
      503,
    );

    expect(
      gemini.generate([hello]),
      throwsA(
        predicate(
          (e) =>
              '$e' == '503: The model is overloaded. Please try again later.',
        ),
      ),
    );
  });

  group('rate limit', () {
    var now = DateTime(2026, 11, 13, 12);
    late List<Duration> slept;

    setUp(() {
      slept = [];
      gemini = GeminiProvider(
        'key',
        clock: () => now,
        sleep: (wait) async {
          slept.add(wait);
          now = now.add(wait);
        },
        client: MockClient((request) async {
          requests.add(request);
          return response;
        }),
      );
    });

    http.Response limited(String delay) => http.Response(
      jsonEncode({
        'error': {
          'code': 429,
          'message':
              'You exceeded your current quota.\n* Quota exceeded for metric',
          'status': 'RESOURCE_EXHAUSTED',
          'details': [
            {'@type': 'type.googleapis.com/google.rpc.QuotaFailure'},
            {
              '@type': 'type.googleapis.com/google.rpc.RetryInfo',
              'retryDelay': delay,
            },
          ],
        },
      }),
      429,
    );

    test('says how long Gemini asked to wait, in a line', () async {
      response = limited('34s');

      await expectLater(
        gemini.generate([hello]),
        throwsA(
          isA<RateLimited>()
              .having((e) => e.retryAfter, 'retryAfter', Duration(seconds: 34))
              .having(
                (e) => e.message,
                'message',
                'You exceeded your current quota.',
              ),
        ),
      );
    });

    test('holds every request back until then', () async {
      response = limited('34s');
      await expectLater(gemini.generate([hello]), throwsA(isA<RateLimited>()));

      respond(
        reply([
          {'text': 'hi'},
        ]),
      );
      now = now.add(const Duration(seconds: 4));
      await gemini.generate([hello]);
      await gemini.countTokens([hello]).catchError((_) => 0);

      expect(slept, [const Duration(seconds: 30)]);
      expect(requests, hasLength(3));
    });

    test('gives up on a request with no answer, and tries again', () async {
      gemini = GeminiProvider(
        'key',
        clock: () => now,
        sleep: (wait) async {
          slept.add(wait);
          now = now.add(wait);
        },
        timeout: const Duration(milliseconds: 20),
        client: MockClient((request) {
          requests.add(request);
          // Gemini holds the first one open
          return requests.length == 1
              ? Completer<http.Response>().future
              : Future.value(response);
        }),
      );
      respond(
        reply([
          {'text': 'hi'},
        ]),
      );

      await expectLater(
        gemini.generate([hello]),
        throwsA(
          isA<TryLater>()
              .having((e) => e.status, 'status', 408)
              .having((e) => e.retryAfter, 'retryAfter', Duration(seconds: 5)),
        ),
      );
      final answer = await gemini.generate([hello]);

      expect((answer.parts.single as TextPart).text, 'hi');
      expect(slept, [const Duration(seconds: 5)]);
      expect(
        retryNote(
          const RetryWait(
            Duration(seconds: 5),
            '',
            status: 408,
            provider: 'Gemini',
          ),
        ),
        "Gemini didn't answer: waiting 5s, then trying again",
      );
    });

    test('backs off from a busy Gemini, longer each time in a row', () async {
      http.Response busy() => http.Response(
        jsonEncode({
          'error': {
            'code': 503,
            'message': 'This model is currently experiencing high demand.',
            'status': 'UNAVAILABLE',
          },
        }),
        503,
      );
      final waits = <Duration?>[];
      Future<void> attempt() async {
        try {
          await gemini.generate([hello]);
          waits.add(null);
        } on TryLater catch (e) {
          expect(e, isNot(isA<RateLimited>()));
          expect(
            '$e',
            '503: This model is currently experiencing high demand.',
          );
          waits.add(e.retryAfter);
        }
      }

      response = busy();
      await attempt();
      await attempt();
      await attempt();
      respond(
        reply([
          {'text': 'hi'},
        ]),
      );
      await attempt();
      response = busy();
      await attempt();

      expect(waits, [
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 20),
        null,
        // a reply starts it over
        const Duration(seconds: 5),
      ]);
      // and each request waited out the one before
      expect(slept, [
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 20),
      ]);
    });
  });

  test('throws when the reply has no content', () async {
    respond({'candidates': []});
    await expectLater(
      gemini.generate([hello]),
      throwsA(predicate((e) => '$e' == 'Exception: receiving candidates')),
    );

    respond({
      'candidates': [{}],
    });
    await expectLater(
      gemini.generate([hello]),
      throwsA(predicate((e) => '$e' == 'Exception: model content is null')),
    );
  });
}
