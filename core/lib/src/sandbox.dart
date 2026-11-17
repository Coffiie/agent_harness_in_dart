import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'diff.dart';
import 'history.dart';
import 'tools.dart';

/// Runs `docker` with [args], feeding it [stdin] when given. Tests swap it.
typedef Docker =
    Future<ProcessResult> Function(List<String> args, {String? stdin});

Future<ProcessResult> _runDocker(List<String> args, {String? stdin}) async {
  if (stdin == null) return Process.run('docker', args);
  final process = await Process.start('docker', args);
  process.stdin.write(stdin);
  await process.stdin.close();
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  return ProcessResult(
    process.pid,
    await process.exitCode,
    await out,
    await err,
  );
}

/// The label every sandbox container gets, with the harness's process id
/// as its value, so a later run can clear away containers whose harness
/// died without stopping them.
const sandboxLabel = 'coding_agent_in_dart.sandbox';

/// A Docker container the agent's tools run in. It has no network, and
/// the only folders it sees from this computer are the project, which it
/// can change, and Dart's package cache, which it can only read, so tests
/// run. Both are mounted at the same paths they have here, so a path
/// means the same thing inside and out.
class Sandbox {
  Sandbox._(this.folder, this.image, this._docker, {this.name, this.problem});

  /// The project folder, as an absolute path.
  final String folder;

  final String image;

  /// The container's name, while it runs.
  final String? name;

  /// Why the sandbox isn't running, when it isn't.
  final String? problem;

  final Docker _docker;
  var _stopped = false;

  bool get running => name != null && !_stopped;

  /// Starts a container for [folder]. When Docker isn't there, or the
  /// image isn't pulled, the sandbox comes back with a [problem] instead,
  /// and every tool refuses to run.
  static Future<Sandbox> start(
    String folder, {
    String? image,
    String? packages,
    Docker docker = _runDocker,
    int? pid,
    Random? random,
  }) async {
    folder = p.normalize(p.absolute(folder));
    image ??= 'dart:${Platform.version.split(' ').first}';
    pid ??= Platform.isWindows ? null : _pid;
    Sandbox off(String problem) =>
        Sandbox._(folder, image!, docker, problem: problem);

    final ProcessResult info;
    try {
      info = await docker(['info', '--format', '{{.ServerVersion}}']);
    } on ProcessException {
      return off("Docker isn't installed");
    }
    if (info.exitCode != 0) return off("Docker isn't running");

    final has = await docker([
      'image',
      'inspect',
      '--format',
      '{{.Id}}',
      image,
    ]);
    if (has.exitCode != 0) return off('run docker pull $image first');

    await _clearDead(docker);

    final name =
        'harness-${(random ?? Random()).nextInt(1 << 32).toRadixString(16)}';
    final cache = packages ?? _packageCache();
    final user = await _user();
    final run = await docker([
      'run', '--detach', '--rm', //
      '--name', name,
      if (pid != null) ...['--label', '$sandboxLabel=$pid'],
      '--network', 'none',
      '--read-only',
      '--tmpfs', '/tmp:rw,exec,size=1g',
      '--cap-drop', 'ALL',
      '--security-opt', 'no-new-privileges',
      '--pids-limit', '512',
      '--memory', '2g',
      '--cpus', '2',
      if (user != null) ...['--user', user],
      '--env', 'HOME=/tmp',
      '--volume', '$folder:$folder',
      if (cache != null && Directory(cache).existsSync()) ...[
        '--volume',
        '$cache:$cache:ro',
        '--env',
        'PUB_CACHE=$cache',
      ],
      '--workdir', folder,
      image,
      'sleep', 'infinity',
    ]);
    if (run.exitCode != 0) {
      return off('Docker could not start it: ${_firstLine(run.stderr)}');
    }
    final box = Sandbox._(folder, image, docker, name: name);
    // Packages resolved out here can name things the box doesn't have, like
    // the Flutter SDK, and then dart test resolves them again, online, and
    // fails. So they're resolved once in here, offline.
    if (File(p.join(folder, 'pubspec.yaml')).existsSync()) {
      await box.exec(['dart', 'pub', 'get', '--offline']);
    }
    return box;
  }

  /// Runs [command] in the container, in the project folder, cut off after
  /// [timeout].
  Future<ProcessResult> exec(
    List<String> command, {
    String? stdin,
    Duration timeout = const Duration(minutes: 2),
  }) => _docker([
    'exec',
    if (stdin != null) '--interactive',
    name!,
    'timeout',
    '${timeout.inSeconds}',
    ...command,
  ], stdin: stdin);

  /// Removes the container.
  Future<void> stop() async {
    if (!running) return;
    _stopped = true;
    await _docker(['rm', '--force', name!]);
  }

  /// The tools, each running inside the container: read, list and update
  /// files, and run commands. With a [history], updateFile records every
  /// edit it makes, so /undo can take it back.
  List<Tool> tools({FileHistory? history}) => [
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
      run: (args) => _guard(() async {
        final read = await exec(['cat', '--', args['path'] as String]);
        if (read.exitCode != 0) return {'error': _firstLine(read.stderr)};
        return {'content': read.stdout};
      }),
    ),
    Tool(
      name: 'listFiles',
      description:
          'List the contents of a directory from a given path, if no path is '
          'provided, list the contents of the current directory. Directories '
          'end with /',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'the path of the directory',
          },
        },
      },
      label: (args) => 'ListFiles(path: ${args['path']})',
      run: (args) => _guard(() async {
        final path = args['path'] as String? ?? folder;
        final list = await exec(['ls', '-1Ap', '--', path]);
        if (list.exitCode != 0) return {'error': _firstLine(list.stderr)};
        return {
          'files': [
            for (final entry in LineSplitter.split(list.stdout as String))
              if (entry.isNotEmpty) p.join(path, entry),
          ],
        };
      }),
    ),
    Tool(
      name: 'updateFile',
      description:
          'Update the contents of the file given a path and contents. '
          'Missing folders are made.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'the path of the file'},
          'content': {
            'type': 'string',
            'description': 'the new contents of the file',
          },
        },
        'required': ['path', 'content'],
      },
      label: (args) => 'UpdateFile(path: ${args['path']})',
      run: (args) => _guard(() async {
        final path = args['path'] as String;
        final content = args['content'] as String;
        final read = await exec(['cat', '--', path]);
        final before = read.exitCode == 0 ? read.stdout as String : null;
        final write = await exec([
          'sh',
          '-c',
          r'mkdir -p "$(dirname "$1")" && cat > "$1"',
          'sh',
          path,
        ], stdin: content);
        if (write.exitCode != 0) {
          return {'status': 'error', 'message': _firstLine(write.stderr)};
        }
        history?.record(Edit(path, before: before, after: content));
        return {'status': 'success'};
      }),
      diff: (args) => _diff(args['path'], args['content']),
    ),
    Tool(
      name: 'runCommand',
      description:
          'Run a shell command in the project folder, like dart test or '
          'dart analyze, and get its output and exit code. It runs in a '
          'sandbox with no network, so nothing can be downloaded, and only '
          'the project folder can be changed. Commands stop after two '
          'minutes.',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': 'the shell command'},
        },
        'required': ['command'],
      },
      label: (args) => 'RunCommand(${args['command']})',
      run: (args) => _guard(() async {
        final run = await exec(['sh', '-c', 'exec 2>&1\n${args['command']}']);
        return {
          'exitCode': run.exitCode == 124 ? 'timed out' : run.exitCode,
          'output': _tail(run.stdout as String),
        };
      }),
    ),
  ];

  Future<Map<String, dynamic>> _guard(
    Future<Map<String, dynamic>> Function() run,
  ) async {
    if (!running) {
      return {
        'error':
            "The sandbox isn't running (${problem ?? 'it was stopped'}), and "
            'tools only run inside it.',
      };
    }
    try {
      return await run();
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  // The diff of an update, from the file as it is here. Only files in the
  // project are the same inside the container, so others get none.
  List<DiffLine> _diff(Object? path, Object? content) {
    if (path is! String || content is! String) return const [];
    final file = p.normalize(p.join(folder, path));
    if (!p.isWithin(folder, file)) return const [];
    if (FileSystemEntity.isDirectorySync(file)) return const [];
    try {
      final before = File(file).existsSync()
          ? File(file).readAsStringSync()
          : '';
      return diffLines(before, content);
    } catch (_) {
      return const [];
    }
  }

  // Removes sandbox containers whose harness isn't running any more.
  static Future<void> _clearDead(Docker docker) async {
    if (Platform.isWindows) return;
    final list = await docker([
      'ps', '--all', //
      '--filter', 'label=$sandboxLabel',
      '--format', '{{.Names}} {{.Label "$sandboxLabel"}}',
    ]);
    if (list.exitCode != 0) return;
    for (final line in LineSplitter.split(list.stdout as String)) {
      if (line.split(' ') case [final name, final pid, ...]) {
        if (pid == '$_pid' || _alive(int.tryParse(pid))) continue;
        await docker(['rm', '--force', name]);
      }
    }
  }
}

int get _pid => pid;

bool _alive(int? pid) =>
    pid != null && Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

// Runs as this computer's user, so files it writes are this user's.
Future<String?> _user() async {
  if (Platform.isWindows) return null;
  final uid = await Process.run('id', ['-u']);
  final gid = await Process.run('id', ['-g']);
  if (uid.exitCode != 0 || gid.exitCode != 0) return null;
  return '${(uid.stdout as String).trim()}:${(gid.stdout as String).trim()}';
}

String? _packageCache() {
  final env = Platform.environment;
  if (env['PUB_CACHE'] case final cache? when cache.isNotEmpty) return cache;
  final home = env['HOME'] ?? env['USERPROFILE'];
  return home == null ? null : p.join(home, '.pub-cache');
}

String _firstLine(Object? text) {
  final lines = LineSplitter.split('$text'.trim());
  return lines.isEmpty ? 'it failed' : lines.first;
}

// Long output keeps its end, where the result and the errors are.
String _tail(String output, [int max = 6000]) => output.length <= max
    ? output
    : '[cut: the first ${output.length - max} characters]\n'
          '${output.substring(output.length - max)}';
