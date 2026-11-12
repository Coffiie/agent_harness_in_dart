import 'dart:async';

import 'package:flutter/material.dart';

/// The TUI's graphite dark theme.
abstract final class Graphite {
  static const primary = Color(0xFFE8E8E8);
  static const secondary = Color(0xFF8C8C8C);
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF262626);
  static const accent = Color(0xFFFFFFFF);
  static const outline = Color(0xFF4A4A4A);
  static const tool = Color(0xFFC4C4C4);
  static const error = Color(0xFFE5837A);
  static const added = Color(0xFF1B2D21);
  static const removed = Color(0xFF3A2120);
}

/// Monospace, like the terminal.
const mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Courier', 'monospace'],
  color: Graphite.primary,
  fontSize: 14,
  height: 1.35,
);

const _eyes = ['▘', '▝', '▗', '▖'];

/// Term's face for [mood] at animation [frame], as in the TUI.
String face(String mood, int frame) => switch (mood) {
  'waiting' => frame.isEven ? '>_' : '> ',
  'working' => _eyes[frame % _eyes.length] * 2,
  'done' => '^^',
  'error' => '××',
  'undo' => '<<',
  'needs' => '??',
  _ => '>_',
};

Color moodColor(String mood) => switch (mood) {
  'error' => Graphite.error,
  'undo' => Graphite.tool,
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
    final every = switch (widget.mood) {
      'working' => const Duration(milliseconds: 250),
      'waiting' => const Duration(milliseconds: 600),
      _ => null,
    };
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
      face(mood, frame),
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
      '▛▀▀▀▀▜\n▙ ${face(mood, frame)} ▟',
      style: mono.copyWith(color: moodColor(mood), height: 1.0),
    ),
  );
}
