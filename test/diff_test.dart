import 'package:coding_agent_in_dart/src/diff.dart';
import 'package:test/test.dart';

List<String> show(List<DiffLine> diff) => [for (final l in diff) '$l'];

void main() {
  test('a new file is all added lines', () {
    expect(show(diffLines('', 'a\nb\n')), ['1 + a', '2 + b']);
  });

  test('a changed line is removed, then added, with its line numbers', () {
    expect(show(diffLines('a\nb\nc\n', 'a\nB\nc\n')), [
      '1   a',
      '2 - b',
      '2 + B',
      '3   c',
    ]);
  });

  test('added and removed lines shift the numbers that follow', () {
    expect(show(diffLines('a\nb\nc', 'a\nnew\nb\nc')), [
      '1   a',
      '2 + new',
      '3   b',
      '4   c',
    ]);
    expect(show(diffLines('a\nb\nc', 'a\nc')), ['1   a', '2 - b', '2   c']);
  });

  test('unchanged lines away from a change are hidden', () {
    final before = [for (var i = 1; i <= 10; i++) 'line $i'].join('\n');
    final after = before
        .replaceFirst('line 2', 'two')
        .replaceFirst('line 9', 'nine');

    expect(show(diffLines(before, after, context: 1)), [
      '1   line 1',
      '2 - line 2',
      '2 + two',
      '3   line 3',
      '⋮',
      '8   line 8',
      '9 - line 9',
      '9 + nine',
      '10   line 10',
    ]);
  });

  test('the same contents have no diff', () {
    expect(diffLines('a\nb', 'a\nb'), isEmpty);
    expect(diffLines('a\r\nb\r\n', 'a\nb'), isEmpty);
  });
}
