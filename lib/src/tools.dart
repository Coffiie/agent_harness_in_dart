import 'dart:io';

import 'diff.dart';
import 'history.dart';

class Tool {
  Tool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.label,
    required this.run,
    this.diff,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final String Function(Map<String, dynamic> args) label;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> args) run;

  /// What [run] is about to change, worked out by the harness, not the model.
  final List<DiffLine> Function(Map<String, dynamic> args)? diff;
}

/// The tools that read, list and update files. With a [history],
/// updateFile records every edit it makes, so /undo can take it back.
List<Tool> fileTools({FileHistory? history}) => [
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
    run: (args) =>
        _updateFile(args['path'] as String, args['content'], history),
    diff: (args) => _fileDiff(args['path'], args['content']),
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

//diffs the file on disk against the contents about to be written
List<DiffLine> _fileDiff(Object? path, Object? content) {
  if (path is! String || content is! String) return const [];
  if (FileSystemEntity.isDirectorySync(path)) return const [];
  try {
    final file = File(path);
    final before = file.existsSync() ? file.readAsStringSync() : '';
    return diffLines(before, content);
  } catch (_) {
    return const [];
  }
}

//update file contents from a given path and content
Future<Map<String, dynamic>> _updateFile(
  String path,
  content,
  FileHistory? history,
) async {
  try {
    final file = File(path);
    final before = file.existsSync() ? file.readAsStringSync() : null;
    await file.writeAsString(content);
    history?.record(Edit(path, before: before, after: content));
    return {'status': 'success'};
  } catch (e) {
    return {'status': 'error', 'message': e.toString()};
  }
}
