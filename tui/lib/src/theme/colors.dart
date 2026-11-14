import 'package:coding_agent_core/coding_agent_core.dart';
import 'package:nocterm/nocterm.dart';

/// The TUI's colors: core's [AppPalette] as nocterm colors. Components
/// read the active one with `context.theme.colors`.
class AppColorsTheme {
  /// Replies, typed text and changed diff lines.
  final Color primary;

  /// Prompts, the model and folder, unchanged diff lines and hints.
  final Color secondary;

  /// The whole screen's background.
  final Color primaryContainer;

  /// Behind inline code and code blocks.
  final Color secondaryContainer;

  /// The app name and Term.
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

  /// [palette] as nocterm colors.
  factory AppColorsTheme.from(
    AppPalette palette, {
    MarkdownStyleSheet? markdown,
  }) => AppColorsTheme._internal(
    primary: Color(palette.primary),
    secondary: Color(palette.secondary),
    primaryContainer: Color(palette.primaryContainer),
    secondaryContainer: Color(palette.secondaryContainer),
    accent: Color(palette.accent),
    focus: Color(palette.focus),
    outline: Color(palette.outline),
    tool: Color(palette.tool),
    code: Color(palette.code),
    error: Color(palette.error),
    added: Color(palette.added),
    removed: Color(palette.removed),
    markdown: markdown,
  );

  /// The first TUI's colors, with nocterm's own markdown colors.
  factory AppColorsTheme.normal() => AppColorsTheme.from(
    AppPalette.normal,
    markdown: MarkdownStyleSheet.terminal(),
  );

  factory AppColorsTheme.graphiteDark() =>
      AppColorsTheme.from(AppPalette.graphiteDark);

  factory AppColorsTheme.graphiteLight() =>
      AppColorsTheme.from(AppPalette.graphiteLight);

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

/// The colors /settings switches to.
extension AppThemeModeColors on AppThemeMode {
  AppColorsTheme get colors => switch (this) {
    AppThemeMode.normal => AppColorsTheme.normal(),
    AppThemeMode.graphiteDark => AppColorsTheme.graphiteDark(),
    AppThemeMode.graphiteLight => AppColorsTheme.graphiteLight(),
  };
}
