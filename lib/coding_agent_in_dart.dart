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
      {
        'name': 'updateFile',
        'description':
            'Update the contents of the file given a path and contents',
        'parameters': {
          'type': 'OBJECT',
          'properties': {
            'path': {
              'type': 'STRING',
              'description': 'the path of the directory',
            },
            'content': {
              'type': 'STRING',
              'description': 'the new contents of the file',
            },
          },
          'required': ['path', 'content'],
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

    if (prompt.contains('/compact')) {
      await _compactConversation(prompt, conversation);
      continue;
    }

    conversation.add({
      'role': 'user',
      'parts': [
        {'text': prompt},
      ],
    });
    await callModel(modelName, conversation);
  }
}

Future<void> _compactConversation(
  String prompt,
  List<Map<String, dynamic>> conversation,
) async {
  final totalTokens = await _countTokens(conversation);

  final compactedConversation = await _summarizeConversation(conversation);
  final compactedTokens = await _countTokens(compactedConversation);

  print(
    '${toolSeparator()} Compacted conversation from $totalTokens tokens to $compactedTokens tokens',
  );
  conversation.clear();
  conversation.addAll(compactedConversation);
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
    case 'updateFile':
      return _updateFile(args['path'] as String, args['content'] as String);
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

//update file contents from a given path and content
Future<Map<String, dynamic>> _updateFile(String path, content) async {
  print('${toolSeparator()} UpdateFile(path: $path)\n');

  try {
    final file = File(path);
    await file.writeAsString(content);
    return {'status': 'success'};
  } catch (e) {
    return {'status': 'error', 'message': e.toString()};
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

Future<List<Map<String, dynamic>>> _summarizeConversation(
  List<Map<String, dynamic>> conversation,
) async {
  print('${toolSeparator()} Summarizing Conversation...\n');

  // fetch api key from environment variable setup in the terminal
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return conversation;
  }

  conversation.add({
    'role': 'user',
    'parts': [
      {
        'text':
            'Please summarize the entire conversation in bullet points. Also remove this prompt to save even more tokens. Give it to me in the form of just 1 text message, and make sure no valuable information is lost. Preserve context and reduce the number of tokens. Start the reply with [CompactedSummaryFromModel]. Please do not discard previous compacted summaries tagged with [CompactedSummaryFromModel]',
      },
    ],
  });

  final uri = Uri.parse('$_baseUrl/$_model:generateContent');

  final body = jsonEncode({'contents': conversation});

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
    body: body,
  );

  if (response.statusCode != 200) {
    throw Exception('${response.statusCode}: ${response.body}');
  }

  final responseBody = jsonDecode(response.body) as Map<String, dynamic>;

  final candidates = responseBody['candidates'] as List<dynamic>?;

  if (candidates == null || candidates.isEmpty) {
    print('Error: receiving candidates');
    conversation.removeLast();
    return conversation;
  }

  final modelContent =
      (candidates.first as Map<String, dynamic>)['content']
          as Map<String, dynamic>?;

  if (modelContent == null) {
    print('Error: model content is null');
    conversation.removeLast();
    return conversation;
  }

  final parts = (modelContent['parts'] as List<dynamic>? ?? [])
      .cast<Map<String, dynamic>>();

  final textParts = parts.where((p) => p.containsKey('text'));

  for (final p in textParts) {
    final text = p['text'] as String?;
    if (text != null && text.isNotEmpty) {
      return [
        {
          'role': 'model',
          'parts': [
            {'text': text},
          ],
        },
      ];
    }
  }

  print('Error: while compacting');
  conversation.removeLast();
  return conversation;
}

Future<int> _countTokens(
  List<Map<String, dynamic>> conversation, {
  String model = _model,
}) async {
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';
  if (apiKey.isEmpty) return -1;

  final uri = Uri.parse('$_baseUrl/$model:countTokens');
  final body = jsonEncode({'contents': conversation});

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
    body: body,
  );

  if (response.statusCode != 200) {
    print(
      '${toolSeparator()} countTokens failed: ${response.statusCode} ${response.body}',
    );
    return -1;
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  return data['totalTokens'] as int? ?? -1;
}
