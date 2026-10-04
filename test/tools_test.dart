import 'dart:io';

import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Tool tool(String name) => fileTools.singleWhere((t) => t.name == name);

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
