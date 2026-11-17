/// Term, the harness's mascot, as text: its moods and faces. The TUI and
/// the phone app both draw it from these.
library;

/// What Term's face shows.
enum Mood {
  /// Nothing running yet. The cursor blinks.
  waiting,

  /// The agent is working. The eyes run round a little square.
  working,

  /// The last turn finished.
  done,

  /// The last turn ended with an error.
  error,

  /// The user ran /undo.
  undo,

  /// The model asked the user something and waits for the answer.
  needs,
}

/// One eye going round a square, clockwise: top left, top right, bottom
/// right, bottom left.
const _eyes = ['▘', '▝', '▗', '▖'];

/// Term's face at animation [frame]: two characters, also used on their own
/// next to "Thinking…".
String face(Mood mood, int frame) => switch (mood) {
  Mood.waiting => frame.isEven ? '>_' : '> ',
  Mood.working => _eyes[frame % _eyes.length] * 2,
  Mood.done => '^^',
  Mood.error => '××',
  Mood.undo => '<<',
  Mood.needs => '??',
};

/// Term's two rows: a little terminal with [face] on its screen. As an
/// orchestrator's, the [lead], it wears a notch like a headset.
List<String> termRows(Mood mood, int frame, {bool lead = false}) => [
  lead ? '▛▀▄▄▀▜' : '▛▀▀▀▀▜',
  '▙ ${face(mood, frame)} ▟',
];

/// How often Term's face moves on to its next frame: while it waits and
/// while it works. The other faces hold still.
Duration? tickEvery(Mood mood) => switch (mood) {
  Mood.waiting => const Duration(milliseconds: 600),
  Mood.working => const Duration(milliseconds: 250),
  Mood.done || Mood.error || Mood.undo || Mood.needs => null,
};
