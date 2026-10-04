import 'dart:io';

class Tool {
  Tool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.label,
    required this.run,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final String Function(Map<String, dynamic> args) label;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> args) run;
}

final fileTools = [
  Tool(
    name: 'readFile',
    description: 'Read the contents of a file from a given path',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'the path of the file'},
      },
      'required': ['path'],
    },
    label: (args) => 'ReadFile(path: ${args['path']})',
    run: (args) => _readFile(args['path'] as String),
  ),
  Tool(
    name: 'listFiles',
    description:
        'List the contents of a directory from a given path, if no path is provided, list the contents of the current directory',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'the path of the directory'},
      },
    },
    label: (args) => 'ListFiles(path: ${args['path']})',
    run: (args) => _listFiles(args['path'] as String?),
  ),
  Tool(
    name: 'updateFile',
    description: 'Update the contents of the file given a path and contents',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'the path of the directory'},
        'content': {
          'type': 'string',
          'description': 'the new contents of the file',
        },
      },
      'required': ['path', 'content'],
    },
    label: (args) => 'UpdateFile(path: ${args['path']})',
    run: (args) => _updateFile(args['path'] as String, args['content']),
  ),
];

//lists files given a path
Future<Map<String, dynamic>> _listFiles(String? path) async {
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
  try {
    final contents = await File(path).readAsString();
    return {'content': contents};
  } catch (e) {
    return {'error': e.toString()};
  }
}

//update file contents from a given path and content
Future<Map<String, dynamic>> _updateFile(String path, content) async {
  try {
    final file = File(path);
    await file.writeAsString(content);
    return {'status': 'success'};
  } catch (e) {
    return {'status': 'error', 'message': e.toString()};
  }
}
