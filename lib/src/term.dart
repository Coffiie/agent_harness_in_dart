import 'package:nocterm/nocterm.dart';

import 'design_system/extensions.dart';

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

/// Term, the harness's mascot. It sits in the header in the theme's accent
/// color, its error color after a failed turn, and its tool color after
/// /undo.
class Term extends StatelessComponent {
  const Term({
    super.key,
    required this.mood,
    this.frame = 0,
    this.lead = false,
  });

  final Mood mood;
  final int frame;

  /// Whether it's an orchestrator's Term.
  final bool lead;

  @override
  Component build(BuildContext context) {
    final colors = context.theme.colors;
    final style = TextStyle(
      color: switch (mood) {
        Mood.error => colors.error,
        Mood.undo => colors.tool,
        _ => colors.accent,
      },
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in termRows(mood, frame, lead: lead))
          Text(row, style: style),
      ],
    );
  }
}
