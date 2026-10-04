import 'dart:convert';

import 'package:coding_agent_in_dart/src/gemini_provider.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
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
    ], tools: fileTools);

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
      throwsA(predicate((e) => '$e' == 'Exception: 403: bad key')),
    );
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
