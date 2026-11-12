import 'dart:io';

import 'package:coding_agent_in_dart/src/diff.dart';
import 'package:coding_agent_in_dart/src/history.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late FileHistory history;

  setUp(() {
    dir = Directory.systemTemp.createTempSync();
    history = FileHistory();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, String content) =>
      File('${dir.path}/$name')..writeAsStringSync(content);

  test('has nothing to undo at first', () {
    expect(history.isEmpty, isTrue);
    expect(history.undo(), isNull);
  });

  test('puts the old contents back, with the diff', () {
    final file = write('a.txt', 'new\n');
    history.record(Edit(file.path, before: 'old\n', after: 'new\n'));

    final undo = history.undo()!;

    expect(file.readAsStringSync(), 'old\n');
    expect(undo.undone, isTrue);
    expect(undo.deleted, isFalse);
    expect(undo.diff.map((l) => (l.change, l.text)), [
      (Change.removed, 'new'),
      (Change.added, 'old'),
    ]);
    expect(history.isEmpty, isTrue);
  });

  test('deletes a file the edit created', () {
    final file = write('b.txt', 'made\n');
    history.record(Edit(file.path, before: null, after: 'made\n'));

    final undo = history.undo()!;

    expect(file.existsSync(), isFalse);
    expect(undo.deleted, isTrue);
    expect(undo.diff.single.change, Change.removed);
  });

  test('takes edits back newest first', () {
    final file = write('c.txt', 'three');
    history
      ..record(Edit(file.path, before: 'one', after: 'two'))
      ..record(Edit(file.path, before: 'two', after: 'three'));

    history.undo();
    expect(file.readAsStringSync(), 'two');
    history.undo();
    expect(file.readAsStringSync(), 'one');
    expect(history.undo(), isNull);
  });

  test('leaves a file alone that changed after the edit', () {
    final file = write('d.txt', 'edited by hand');
    history.record(Edit(file.path, before: 'old', after: 'new'));

    final undo = history.undo()!;

    expect(undo.changedSince, isTrue);
    expect(undo.undone, isFalse);
    expect(file.readAsStringSync(), 'edited by hand');
    expect(history.isEmpty, isTrue);
  });

  test('clear forgets every edit', () {
    history.record(const Edit('x', before: 'a', after: 'b'));
    history.clear();
    expect(history.undo(), isNull);
  });
}
