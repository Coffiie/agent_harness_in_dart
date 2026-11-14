import 'dart:io';

import 'package:coding_agent_core/src/diff.dart';
import 'package:coding_agent_core/src/history.dart';
import 'package:coding_agent_core/src/tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Tool tool(String name) => fileTools().singleWhere((t) => t.name == name);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync());
  tearDown(() => dir.deleteSync(recursive: true));

  test('readFile returns the file contents', () async {
    final path = p.join(dir.path, 'a.txt');
    File(path).writeAsStringSync('hello');

    expect(await tool('readFile').run({'path': path}), {'content': 'hello'});
  });

  test('listFiles lists the directory', () async {
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('');

    expect(await tool('listFiles').run({'path': dir.path}), {
      'files': [p.join(dir.path, 'a.txt')],
    });
  });

  test('updateFile writes the contents', () async {
    final path = p.join(dir.path, 'a.txt');

    expect(await tool('updateFile').run({'path': path, 'content': 'new'}), {
      'status': 'success',
    });
    expect(File(path).readAsStringSync(), 'new');
  });

  test('updateFile records each edit so it can be undone', () async {
    final history = FileHistory();
    final update = fileTools(
      history: history,
    ).singleWhere((t) => t.name == 'updateFile');
    final old = p.join(dir.path, 'old.txt');
    final made = p.join(dir.path, 'made.txt');
    File(old).writeAsStringSync('before');

    await update.run({'path': old, 'content': 'after'});
    await update.run({'path': made, 'content': 'new file'});

    expect(history.undo()!.deleted, isTrue);
    expect(File(made).existsSync(), isFalse);
    expect(history.undo()!.undone, isTrue);
    expect(File(old).readAsStringSync(), 'before');
  });

  test('a write that fails records nothing', () async {
    final history = FileHistory();
    final update = fileTools(
      history: history,
    ).singleWhere((t) => t.name == 'updateFile');

    await update.run({'path': dir.path, 'content': 'x'});

    expect(history.isEmpty, isTrue);
  });

  test('updateFile diffs the file on disk against the new contents', () {
    final path = p.join(dir.path, 'a.txt');
    File(path).writeAsStringSync('a\nb\n');

    final diff = tool('updateFile').diff!({'path': path, 'content': 'a\nc\n'});

    expect([for (final l in diff) '$l'], ['1   a', '2 - b', '2 + c']);
    expect(File(path).readAsStringSync(), 'a\nb\n');
  });

  test('a new file diffs as all added, a bad path as nothing', () {
    final diff = tool('updateFile').diff!;

    expect(diff({'path': p.join(dir.path, 'new.txt'), 'content': 'x'}), [
      isA<DiffLine>().having((l) => l.change, 'change', Change.added),
    ]);
    expect(diff({'path': dir.path, 'content': 'x'}), isEmpty);
    expect(diff({'content': 'x'}), isEmpty);
  });

  test('only updateFile has a diff', () {
    expect(tool('readFile').diff, isNull);
    expect(tool('listFiles').diff, isNull);
  });

  test('failures come back as results', () async {
    final missing = p.join(dir.path, 'missing', 'a.txt');

    expect(await tool('readFile').run({'path': missing}), contains('error'));
    expect(await tool('listFiles').run({'path': missing}), contains('error'));
    expect(
      await tool('updateFile').run({'path': missing, 'content': ''}),
      containsPair('status', 'error'),
    );
  });

  test('labels name the tool and its path', () {
    expect(tool('readFile').label({'path': 'a.txt'}), 'ReadFile(path: a.txt)');
    expect(tool('listFiles').label({}), 'ListFiles(path: null)');
    expect(
      tool('updateFile').label({'path': 'a.txt', 'content': 'new'}),
      'UpdateFile(path: a.txt)',
    );
  });
}
