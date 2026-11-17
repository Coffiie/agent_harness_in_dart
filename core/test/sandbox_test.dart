import 'dart:io';

import 'package:coding_agent_core/src/history.dart';
import 'package:coding_agent_core/src/sandbox.dart';
import 'package:coding_agent_core/src/tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ProcessResult ok([String out = '']) => ProcessResult(0, 0, out, '');
ProcessResult fail(String err, [int code = 1]) =>
    ProcessResult(0, code, '', err);

/// Docker as the tests want it: [exec] answers `docker exec`, and every
/// other command succeeds unless [answers] says otherwise.
class FakeDocker {
  FakeDocker({this.answers = const {}, this.exec});

  final Map<String, ProcessResult> answers;
  final ProcessResult Function(List<String> command, String? stdin)? exec;
  final calls = <List<String>>[];
  final stdins = <String?>[];

  Future<ProcessResult> call(List<String> args, {String? stdin}) async {
    calls.add(args);
    stdins.add(stdin);
    if (answers[args.first] case final answer?) return answer;
    if (args.first == 'exec') {
      // exec [--interactive] <name> timeout <seconds> <command...>
      final command = args.sublist(args.indexOf('timeout') + 2);
      return exec?.call(command, stdin) ?? ok();
    }
    return ok();
  }

  List<String> get run => calls.singleWhere((c) => c.first == 'run');
}

Tool tool(Sandbox box, String name, {FileHistory? history}) =>
    box.tools(history: history).singleWhere((t) => t.name == name);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync());
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Sandbox> start(FakeDocker docker, {String? packages}) => Sandbox.start(
    dir.path,
    image: 'dart:test',
    packages: packages,
    docker: docker.call,
  );

  group('starting', () {
    test('without Docker, every tool refuses and says why', () async {
      final box = await Sandbox.start(
        dir.path,
        image: 'dart:test',
        docker: (args, {stdin}) => throw const ProcessException('docker', []),
      );

      expect(box.running, isFalse);
      expect(box.problem, "Docker isn't installed");
      for (final t in box.tools()) {
        final result = await t.run({
          'path': 'a',
          'content': '',
          'command': 'ls',
        });
        expect(result['error'], contains("The sandbox isn't running"));
        expect(result['error'], contains("Docker isn't installed"));
      }
    });

    test("when Docker isn't running", () async {
      final box = await start(FakeDocker(answers: {'info': fail('no daemon')}));

      expect(box.problem, "Docker isn't running");
    });

    test("when the image isn't pulled, it says which to pull", () async {
      final docker = FakeDocker(answers: {'image': fail('no such image')});
      final box = await start(docker);

      expect(box.problem, 'run docker pull dart:test first');
      expect(docker.calls.where((c) => c.first == 'run'), isEmpty);
    });

    test('the container has no network and sees only the project and, '
        'read-only, the package cache', () async {
      final cache = Directory(p.join(dir.path, 'cache'))..createSync();
      final docker = FakeDocker();
      final box = await start(docker, packages: cache.path);
      final folder = p.normalize(p.absolute(dir.path));
      final run = docker.run.join(' ');

      expect(box.running, isTrue);
      expect(run, contains('--network none'));
      expect(run, contains('--read-only'));
      expect(run, contains('--cap-drop ALL'));
      expect(run, contains('--security-opt no-new-privileges'));
      expect(run, contains('--volume $folder:$folder '));
      expect(run, contains('--volume ${cache.path}:${cache.path}:ro'));
      expect(run, contains('--env PUB_CACHE=${cache.path}'));
      expect(run, contains('--workdir $folder'));
      expect(run, endsWith('dart:test sleep infinity'));
      // the two volumes, and nothing else from this computer
      final volumes = [
        for (final (i, arg) in docker.run.indexed)
          if (arg == '--volume') docker.run[i + 1],
      ];
      expect(volumes, ['$folder:$folder', '${cache.path}:${cache.path}:ro']);
    });

    test(
      'resolves Dart packages offline, inside, when there are any',
      () async {
        final docker = FakeDocker();
        await start(docker);
        expect(docker.calls.where((c) => c.first == 'exec'), isEmpty);

        File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: x');
        final again = FakeDocker();
        await start(again);
        final exec = again.calls.singleWhere((c) => c.first == 'exec');
        expect(exec.sublist(exec.indexOf('timeout') + 2), [
          'dart',
          'pub',
          'get',
          '--offline',
        ]);
      },
    );

    test('clears away containers whose harness died', () async {
      final docker = FakeDocker(
        answers: {'ps': ok('harness-dead 999999\nharness-live $pid\n')},
      );
      await start(docker);

      final removed = docker.calls.where((c) => c.first == 'rm');
      expect(removed, [
        ['rm', '--force', 'harness-dead'],
      ]);
    });

    test('stop removes the container, and tools refuse after', () async {
      final docker = FakeDocker();
      final box = await start(docker);
      final name = docker.run[docker.run.indexOf('--name') + 1];

      await box.stop();

      expect(docker.calls.last, ['rm', '--force', name]);
      expect(box.running, isFalse);
      final result = await tool(box, 'readFile').run({'path': 'a'});
      expect(result['error'], contains("The sandbox isn't running"));
    });
  });

  group('tools run inside it', () {
    test('readFile reads with cat in the container', () async {
      final docker = FakeDocker(
        exec: (command, _) => command[0] == 'cat' && command[2] == 'a.txt'
            ? ok('hello')
            : fail('cat: ${command.last}: No such file or directory'),
      );
      final box = await start(docker);

      expect(await tool(box, 'readFile').run({'path': 'a.txt'}), {
        'content': 'hello',
      });
      expect(await tool(box, 'readFile').run({'path': '/Users/me/.ssh/id'}), {
        'error': 'cat: /Users/me/.ssh/id: No such file or directory',
      });
    });

    test('listFiles lists with ls, folders ending in /', () async {
      final docker = FakeDocker(exec: (command, _) => ok('a.txt\nlib/\n'));
      final box = await start(docker);

      expect(await tool(box, 'listFiles').run({'path': 'x'}), {
        'files': ['x/a.txt', 'x/lib/'],
      });
      final folder = p.normalize(p.absolute(dir.path));
      expect(await tool(box, 'listFiles').run({}), {
        'files': ['$folder/a.txt', '$folder/lib/'],
      });
    });

    test(
      'updateFile writes through the container and records the edit',
      () async {
        final docker = FakeDocker(
          exec: (command, stdin) => command[0] == 'cat' ? ok('before') : ok(),
        );
        final history = FileHistory();
        final box = await start(docker);

        final result = await tool(
          box,
          'updateFile',
          history: history,
        ).run({'path': 'lib/a.dart', 'content': 'after'});

        expect(result, {'status': 'success'});
        expect(docker.stdins.last, 'after');
        expect(docker.calls.last, contains('--interactive'));
        expect(docker.calls.last.last, 'lib/a.dart');
        expect(history.undo()!.path, 'lib/a.dart');
      },
    );

    test('a write the container refuses records nothing', () async {
      final docker = FakeDocker(
        exec: (command, _) => command[0] == 'cat'
            ? fail('no such file')
            : fail('sh: 1: cannot create /etc/x: Read-only file system', 2),
      );
      final history = FileHistory();
      final box = await start(docker);

      final result = await tool(
        box,
        'updateFile',
        history: history,
      ).run({'path': '/etc/x', 'content': 'y'});

      expect(result, {
        'status': 'error',
        'message': 'sh: 1: cannot create /etc/x: Read-only file system',
      });
      expect(history.undo(), isNull);
    });

    test('the diff comes from files in the project only', () async {
      final box = await start(FakeDocker());
      File(p.join(dir.path, 'a.txt')).writeAsStringSync('one\n');
      final update = tool(box, 'updateFile');

      expect(update.diff!({'path': 'a.txt', 'content': 'two\n'}), isNotEmpty);
      expect(
        update.diff!({'path': p.join(dir.path, 'a.txt'), 'content': 'two\n'}),
        isNotEmpty,
      );
      expect(update.diff!({'path': '../outside', 'content': 'x'}), isEmpty);
      expect(update.diff!({'path': '/etc/hosts', 'content': 'x'}), isEmpty);
    });

    test('runCommand returns the output and the exit code', () async {
      final docker = FakeDocker(
        exec: (command, _) => ProcessResult(0, 1, 'Some tests failed.\n', ''),
      );
      final box = await start(docker);

      expect(await tool(box, 'runCommand').run({'command': 'dart test'}), {
        'exitCode': 1,
        'output': 'Some tests failed.\n',
      });
      final exec = docker.calls.last;
      expect(exec.sublist(exec.indexOf('timeout')), [
        'timeout',
        '120',
        'sh',
        '-c',
        'exec 2>&1\ndart test',
      ]);
    });

    test('a command that runs too long is stopped', () async {
      final docker = FakeDocker(exec: (command, _) => fail('', 124));
      final box = await start(docker);

      final result = await tool(
        box,
        'runCommand',
      ).run({'command': 'sleep 1000'});

      expect(result['exitCode'], 'timed out');
    });

    test('long output keeps its end', () async {
      final long = '${'x' * 10000}THE END';
      final docker = FakeDocker(exec: (command, _) => ok(long));
      final box = await start(docker);

      final result = await tool(box, 'runCommand').run({'command': 'cat big'});
      final output = result['output'] as String;

      expect(output, endsWith('THE END'));
      expect(output, startsWith('[cut: the first'));
      expect(output.length, lessThan(6100));
    });
  });

  // The real thing, when Docker runs here and has the image.
  final image = 'dart:${Platform.version.split(' ').first}';
  final ready =
      Process.runSync('docker', ['image', 'inspect', image]).exitCode == 0;

  group('in Docker', () {
    late Sandbox box;

    setUp(() async {
      box = await Sandbox.start(dir.path);
      expect(box.problem, isNull);
    });
    tearDown(() => box.stop());

    test('writes land in the project folder here', () async {
      await tool(
        box,
        'updateFile',
      ).run({'path': 'lib/made.txt', 'content': 'from the box'});

      expect(
        File(p.join(dir.path, 'lib', 'made.txt')).readAsStringSync(),
        'from the box',
      );
    });

    test("the home folder here isn't there", () async {
      final home = Platform.environment['HOME']!;
      final probe = File(p.join(home, '.sandbox-probe'))
        ..writeAsStringSync('secret');
      addTearDown(probe.deleteSync);

      final read = await tool(box, 'readFile').run({'path': probe.path});

      expect(read['error'], contains('No such file or directory'));
    });

    test('there is no network', () async {
      final run = await tool(box, 'runCommand').run({
        'command':
            'grep -c . /proc/net/route; '
            'getent hosts pub.dev || echo no names; '
            'bash -c "echo > /dev/tcp/1.1.1.1/443" || echo no route',
      });

      // the route table has its header and nothing else
      expect(run['output'], startsWith('1\n'));
      expect(run['output'], contains('no names'));
      expect(run['output'], contains('Network is unreachable'));
      expect(run['output'], endsWith('no route\n'));
    });

    test('only the project can change', () async {
      final run = await tool(
        box,
        'runCommand',
      ).run({'command': 'touch /usr/x'});

      expect(run['exitCode'], isNot(0));
      expect(run['output'], contains('Read-only file system'));
    });

    test(
      "dart test runs on this project's packages",
      () async {
        final copy = Directory(p.join(dir.path, 'project'))..createSync();
        final here = Directory.current.path;
        for (final name in ['pubspec.yaml', 'pubspec.lock']) {
          File(p.join(here, name)).copySync(p.join(copy.path, name));
        }
        Directory(p.join(copy.path, 'test')).createSync();
        File(
          p.join(here, 'test', 'diff_test.dart'),
        ).copySync(p.join(copy.path, 'test', 'diff_test.dart'));
        Directory(p.join(copy.path, 'lib', 'src')).createSync(recursive: true);
        File(
          p.join(here, 'lib', 'src', 'diff.dart'),
        ).copySync(p.join(copy.path, 'lib', 'src', 'diff.dart'));
        // resolved out here first, the way a project is
        expect(
          Process.runSync('dart', [
            'pub',
            'get',
            '--offline',
          ], workingDirectory: copy.path).exitCode,
          0,
        );
        final inside = await Sandbox.start(copy.path);
        addTearDown(inside.stop);

        final run = await tool(
          inside,
          'runCommand',
        ).run({'command': 'dart test test/diff_test.dart'});

        expect(run['output'], contains('All tests passed!'));
        expect(run['exitCode'], 0);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('Dart runs', () async {
      File(
        p.join(dir.path, 'hi.dart'),
      ).writeAsStringSync("void main() => print('hi from the box');");

      final run = await tool(
        box,
        'runCommand',
      ).run({'command': 'dart run hi.dart'});

      expect(run, {'exitCode': 0, 'output': contains('hi from the box')});
    });
  }, skip: ready ? false : 'Docker with the $image image is not here');
}
