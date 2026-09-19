import 'dart:io';

import '../core/tool.dart';

/// Built-in filesystem tools for the coding agent.
List<Tool> fileTools() => [
  Tool(
    spec: const ToolSpec(
      name: 'readFile',
      description: 'Read the contents of a file from a given path',
      parameters: [
        ToolParameter(
          name: 'path',
          type: 'STRING',
          description: 'the path of the file',
          required: true,
        ),
      ],
    ),
    handler: (args) => _readFile(args['path'] as String),
  ),
  Tool(
    spec: const ToolSpec(
      name: 'listFiles',
      description:
          'List the contents of a directory from a given path, if no path is provided, list the contents of the current directory',
      parameters: [
        ToolParameter(
          name: 'path',
          type: 'STRING',
          description: 'the path of the directory',
        ),
      ],
    ),
    handler: (args) => _listFiles(args['path'] as String?),
  ),
  Tool(
    spec: const ToolSpec(
      name: 'updateFile',
      description: 'Update the contents of the file given a path and contents',
      parameters: [
        ToolParameter(
          name: 'path',
          type: 'STRING',
          description: 'the path of the directory',
          required: true,
        ),
        ToolParameter(
          name: 'content',
          type: 'STRING',
          description: 'the new contents of the file',
          required: true,
        ),
      ],
    ),
    handler: (args) =>
        _updateFile(args['path'] as String, args['content'] as String),
  ),
];

Future<Map<String, dynamic>> _listFiles(String? path) async {
  final directory = path == null ? Directory.current : Directory(path);
  try {
    final files = directory.listSync();
    return {'files': files.map((e) => e.path).toList()};
  } catch (e) {
    return {'error': e.toString()};
  }
}

Future<Map<String, dynamic>> _readFile(String path) async {
  try {
    final contents = await File(path).readAsString();
    return {'content': contents};
  } catch (e) {
    return {'error': e.toString()};
  }
}

Future<Map<String, dynamic>> _updateFile(String path, String content) async {
  try {
    final file = File(path);
    await file.writeAsString(content);
    return {'status': 'success'};
  } catch (e) {
    return {'status': 'error', 'message': e.toString()};
  }
}
