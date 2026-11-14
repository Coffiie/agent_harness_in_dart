import 'package:coding_agent_core/coding_agent_core.dart';
import 'package:nocterm/nocterm.dart';

import 'extensions.dart';

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
