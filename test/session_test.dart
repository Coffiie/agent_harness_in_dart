import 'package:coding_agent_in_dart/src/session.dart';
import 'package:test/test.dart';

void main() {
  group('sessionName', () {
    test('keeps the words that say something, up to 16 characters', () {
      expect(
        sessionName('write a tower of hanoi algorithm in lib/hanoi.dart'),
        'tower hanoi',
      );
      expect(sessionName('add a test for solveHanoi'), 'test solveHanoi');
      expect(sessionName('and the second city?'), 'second city');
    });

    test('keeps only the file name of a path', () {
      expect(sessionName('fix lib/src/agent.dart'), 'fix agent.dart');
    });

    test('cuts a long first word', () {
      expect(sessionName('supercalifragilistic words'), 'supercalifragil…');
    });

    test('falls back to the prompt when every word is filler', () {
      expect(sessionName('do it'), 'do it');
    });
  });
}
