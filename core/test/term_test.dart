import 'package:coding_agent_core/src/design_system/term.dart';
import 'package:test/test.dart';

void main() {
  test('blinks the cursor while waiting', () {
    expect(face(Mood.waiting, 0), '>_');
    expect(face(Mood.waiting, 1), '> ');
    expect(face(Mood.waiting, 2), '>_');
  });

  test('runs the eyes round a square while working', () {
    expect(
      [for (var f = 0; f < 5; f++) face(Mood.working, f)],
      ['▘▘', '▝▝', '▗▗', '▖▖', '▘▘'],
    );
  });

  test('holds still when done, failed or undone', () {
    expect({face(Mood.done, 0), face(Mood.done, 3)}, {'^^'});
    expect({face(Mood.error, 0), face(Mood.error, 3)}, {'××'});
    expect({face(Mood.undo, 0), face(Mood.undo, 3)}, {'<<'});
    expect({face(Mood.needs, 0), face(Mood.needs, 3)}, {'??'});
  });

  test('draws the face on a two-row terminal', () {
    expect(termRows(Mood.done, 0), ['▛▀▀▀▀▜', '▙ ^^ ▟']);
    for (final mood in Mood.values) {
      expect(termRows(mood, 1).map((row) => row.runes.length), [6, 6]);
    }
  });
}
