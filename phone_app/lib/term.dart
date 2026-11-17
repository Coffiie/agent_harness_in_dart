import 'dart:async';

import 'package:coding_agent_core/design_system.dart';
import 'package:flutter/material.dart';

/// The TUI's graphite dark theme, from core's design system.
abstract final class Graphite {
  static const _palette = AppPalette.graphiteDark;
  static final primary = Color(_palette.primary);
  static final secondary = Color(_palette.secondary);
  static final background = Color(_palette.primaryContainer);
  static final surface = Color(_palette.secondaryContainer);
  static final accent = Color(_palette.accent);
  static final outline = Color(_palette.outline);
  static final tool = Color(_palette.tool);
  static final error = Color(_palette.error);
  static final added = Color(_palette.added);
  static final removed = Color(_palette.removed);
}

/// Monospace, like the terminal.
final mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Courier', 'monospace'],
  color: Graphite.primary,
  fontSize: 14,
  height: 1.35,
);

/// The [Mood] the TUI sent by name. One this app doesn't know shows as
/// waiting.
Mood moodNamed(String mood) => Mood.values.asNameMap()[mood] ?? Mood.waiting;

Color moodColor(String mood) => switch (moodNamed(mood)) {
  Mood.error => Graphite.error,
  Mood.undo => Graphite.tool,
  _ => Graphite.accent,
};

/// Ticks for Term's animation: every 250 ms while working, 600 ms while
/// waiting, and not at all for the other faces.
class Ticking extends StatefulWidget {
  const Ticking({super.key, required this.mood, required this.builder});

  final String mood;
  final Widget Function(BuildContext context, int frame) builder;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  Timer? _timer;
  var _frame = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(Ticking old) {
    super.didUpdateWidget(old);
    if (old.mood != widget.mood) _start();
  }

  void _start() {
    _timer?.cancel();
    _frame = 0;
    final every = tickEvery(moodNamed(widget.mood));
    if (every != null) {
      _timer = Timer.periodic(every, (_) => setState(() => _frame++));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _frame);
}

/// Term's face alone, for lists.
class MiniTerm extends StatelessWidget {
  const MiniTerm({super.key, required this.mood, this.size = 14});

  final String mood;
  final double size;

  @override
  Widget build(BuildContext context) => Ticking(
    mood: mood,
    builder: (context, frame) => Text(
      face(moodNamed(mood), frame),
      style: mono.copyWith(color: moodColor(mood), fontSize: size),
    ),
  );
}

/// Term: a little terminal with its face on the screen.
class Term extends StatelessWidget {
  const Term({super.key, required this.mood});

  final String mood;

  @override
  Widget build(BuildContext context) => Ticking(
    mood: mood,
    builder: (context, frame) => Text(
      termRows(moodNamed(mood), frame).join('\n'),
      style: mono.copyWith(color: moodColor(mood), height: 1.0),
    ),
  );
}
