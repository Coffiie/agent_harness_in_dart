import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

String divider() {
  return '-' * 20;
}

String toolSeparator() {
  return '┃';
}

String input() {
  stdout.write('${divider()}\n');
  stdout.write('You: ');
  final input = stdin.readLineSync() ?? '';
  stdout.write('${divider()}\n');
  return input;
}

const _model = 'gemini-3.1-flash-lite';
const _baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models';

final List<Map<String, dynamic>> _tools = [
  {
    'functionDeclarations': [
      {
        'name': 'readFile',
        'description': 'Read the contents of a file from a given path',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'path': {'type': 'STRING', 'description': 'the path of the file'},
          },
          'required': ['path'],
        },
      },
      {
        'name': 'listFiles',
        'description':
            'List the contents of a directory from a given path, if no path is provided, list the contents of the current directory',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'path': {
              'type': 'STRING',
              'description': 'the path of the directory',
            },
          },
        },
      },
    ],
  },
];

void main(List<String> arguments) async {
  final conversation = <Map<String, dynamic>>[];

  final modelName = 'gemini-3.1-flash-lite';
  print(divider());
  print('Chat with $modelName: (press ctrl-c to exit)');
  print(divider());

  while (true) {
    final prompt = input();
    conversation.add({
      'role': 'user',
      'parts': [
        {'text': prompt},
      ],
    });
    await callModel(modelName, conversation);
  }
}

Future<void> callModel(
  String modelName,
  List<Map<String, dynamic>> conversation,
) async {
  try {
    while (true) {
      final response = await generateContent(conversation);

      final candidates = response['candidates'] as List<dynamic>?;

      if (candidates == null || candidates.isEmpty) {
        print('Error: receiving candidates');
        return;
      }

      final modelContent =
          (candidates.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>?;

      if (modelContent == null) {
        print('Error: model content is null');
        return;
      }

      // this is what preserves thoughtSignature
      conversation.add(modelContent);

      final parts = (modelContent['parts'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();

      final functionCalls = parts.where((p) => p.containsKey('functionCall'));
      final textParts = parts.where((p) => p.containsKey('text'));

      for (final p in textParts) {
        final text = p['text'] as String?;
        if (text != null && text.isNotEmpty) {
          print('$_model: $text');
        }
      }

      //exit loop if only text is returned, this means no function calls
      if (functionCalls.isEmpty) {
        return;
      }

      final responseParts = <Map<String, dynamic>>[];
      for (final call in functionCalls) {
        final fc = call['functionCall'] as Map<String, dynamic>;
        final name = fc['name'] as String;
        final args = (fc['args'] as Map<String, dynamic>?) ?? {};

        final result = await _executeFunction(name, args);

        responseParts.add({
          'functionResponse': {'name': name, 'response': result},
        });
      }

      conversation.add({'role': 'user', 'parts': responseParts});
    }
  } catch (e) {
    print('Error generating content: $e');
  }
}

Future<Map<String, dynamic>> _executeFunction(
  String name,
  Map<String, dynamic> args,
) async {
  switch (name) {
    case 'readFile':
      return _readFile(args['path'] as String);
    case 'listFiles':
      return _listFiles(args['path'] as String?);
    default:
      return {'error': 'Unknown function: $name'};
  }
}

//lists files given a path
Future<Map<String, dynamic>> _listFiles(String? path) async {
  print('${toolSeparator()} ListFiles(path: $path)\n');
  final directory = path == null ? Directory.current : Directory(path);
  try {
    final files = directory.listSync();
    return {'files': files.map((e) => e.path).toList()};
  } catch (e) {
    return {'error': e.toString()};
  }
}

//reads file from a given path
Future<Map<String, dynamic>> _readFile(String path) async {
  print('${toolSeparator()} ReadFile(path: $path)\n');

  try {
    final contents = await File(path).readAsString();
    return {'content': contents};
  } catch (e) {
    return {'error': e.toString()};
  }
}

Future<Map<String, dynamic>> generateContent(
  List<Map<String, dynamic>> conversation,
) async {
  // fetch api key from environment variable setup in the terminal
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return {};
  }

  final uri = Uri.parse('$_baseUrl/$_model:generateContent');

  final body = jsonEncode({'contents': conversation, 'tools': _tools});

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
    body: body,
  );

  if (response.statusCode != 200) {
    throw Exception('${response.statusCode}: ${response.body}');
  }

  return jsonDecode(response.body) as Map<String, dynamic>;
}
