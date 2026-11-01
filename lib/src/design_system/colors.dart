import 'package:nocterm/nocterm.dart';

/// The TUI's colors. Each factory is one theme, and components read the
/// active one with `context.theme.colors`.
class AppColorsTheme {
  /// Replies, typed text and changed diff lines.
  final Color primary;

  /// Prompts, the model and folder, unchanged diff lines and hints.
  final Color secondary;

  /// The whole screen's background.
  final Color primaryContainer;

  /// Behind inline code and code blocks.
  final Color secondaryContainer;

  /// The app name and the spinner.
  final Color accent;

  /// The input box and its cursor.
  final Color focus;

  /// The header's border.
  final Color outline;

  /// Tool calls and compaction results.
  final Color tool;

  /// Inline code and code blocks.
  final Color code;

  final Color error;

  /// Behind added diff lines.
  final Color added;

  /// Behind removed diff lines.
  final Color removed;

  /// How replies are drawn. Built from the colors above unless a theme
  /// passes its own.
  final MarkdownStyleSheet markdown;

  AppColorsTheme._internal({
    required this.primary,
    required this.secondary,
    required this.primaryContainer,
    required this.secondaryContainer,
    required this.accent,
    required this.focus,
    required this.outline,
    required this.tool,
    required this.code,
    required this.error,
    required this.added,
    required this.removed,
    MarkdownStyleSheet? markdown,
  }) : markdown =
           markdown ?? _markdown(primary, secondary, code, secondaryContainer);

  /// The first TUI's colors, with nocterm's own markdown colors.
  factory AppColorsTheme.normal() => AppColorsTheme._internal(
    primary: const Color.fromRGB(243, 237, 230),
    secondary: const Color.fromRGB(169, 178, 176),
    primaryContainer: const Color.fromRGB(0, 0, 0),
    secondaryContainer: Colors.black,
    accent: const Color.fromRGB(242, 182, 148),
    focus: const Color.fromRGB(242, 182, 148),
    outline: const Color.fromRGB(169, 178, 176),
    tool: const Color.fromRGB(167, 207, 194),
    code: Colors.yellow,
    error: const Color.fromRGB(229, 120, 107),
    added: const Color.fromRGB(33, 66, 45),
    removed: const Color.fromRGB(84, 36, 36),
    markdown: MarkdownStyleSheet.terminal(),
  );

  factory AppColorsTheme.graphiteDark() => AppColorsTheme._internal(
    primary: const Color.fromRGB(232, 232, 232),
    secondary: const Color.fromRGB(140, 140, 140),
    primaryContainer: const Color.fromRGB(0, 0, 0),
    secondaryContainer: const Color.fromRGB(38, 38, 38),
    accent: const Color.fromRGB(255, 255, 255),
    focus: const Color.fromRGB(196, 196, 196),
    outline: const Color.fromRGB(74, 74, 74),
    tool: const Color.fromRGB(196, 196, 196),
    code: const Color.fromRGB(242, 242, 242),
    error: const Color.fromRGB(229, 131, 122),
    added: const Color.fromRGB(27, 45, 33),
    removed: const Color.fromRGB(58, 33, 32),
  );

  factory AppColorsTheme.graphiteLight() => AppColorsTheme._internal(
    primary: const Color.fromRGB(31, 31, 31),
    secondary: const Color.fromRGB(107, 107, 107),
    primaryContainer: const Color.fromRGB(250, 250, 250),
    secondaryContainer: const Color.fromRGB(232, 232, 232),
    accent: const Color.fromRGB(0, 0, 0),
    focus: const Color.fromRGB(68, 68, 68),
    outline: const Color.fromRGB(201, 201, 201),
    tool: const Color.fromRGB(68, 68, 68),
    code: const Color.fromRGB(26, 26, 26),
    error: const Color.fromRGB(179, 38, 30),
    added: const Color.fromRGB(220, 239, 224),
    removed: const Color.fromRGB(246, 220, 218),
  );

  static MarkdownStyleSheet _markdown(
    Color text,
    Color muted,
    Color code,
    Color codeBackground,
  ) {
    final heading = TextStyle(color: text, fontWeight: FontWeight.bold);
    final codeStyle = TextStyle(color: code, backgroundColor: codeBackground);
    return MarkdownStyleSheet(
      h1Style: heading,
      h2Style: heading,
      h3Style: heading,
      h4Style: heading,
      h5Style: heading,
      h6Style: heading,
      paragraphStyle: TextStyle(color: text),
      boldStyle: const TextStyle(fontWeight: FontWeight.bold),
      italicStyle: const TextStyle(fontStyle: FontStyle.italic),
      strikethroughStyle: const TextStyle(
        decoration: TextDecoration.lineThrough,
      ),
      codeStyle: codeStyle,
      codeBlockStyle: codeStyle,
      blockquoteStyle: TextStyle(color: muted, fontStyle: FontStyle.italic),
      linkStyle: TextStyle(color: text, decoration: TextDecoration.underline),
    );
  }
}
