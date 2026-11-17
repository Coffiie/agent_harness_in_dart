/// The harness's colors as 0xAARRGGBB values, with no UI library in them,
/// so the TUI and the phone app draw from the same palette: the TUI turns
/// them into nocterm colors, the phone app into Flutter ones.
class AppPalette {
  const AppPalette({
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
  });

  /// Replies, typed text and changed diff lines.
  final int primary;

  /// Prompts, the model and folder, unchanged diff lines and hints.
  final int secondary;

  /// The whole screen's background.
  final int primaryContainer;

  /// Behind inline code and code blocks.
  final int secondaryContainer;

  /// The app name and Term.
  final int accent;

  /// The input box and its cursor.
  final int focus;

  /// The header's border.
  final int outline;

  /// Tool calls and compaction results.
  final int tool;

  /// Inline code and code blocks.
  final int code;

  final int error;

  /// Behind added diff lines.
  final int added;

  /// Behind removed diff lines.
  final int removed;

  /// The first TUI's colors.
  static const normal = AppPalette(
    primary: 0xFFF3EDE6,
    secondary: 0xFFA9B2B0,
    primaryContainer: 0xFF000000,
    secondaryContainer: 0xFF18181C,
    accent: 0xFFF2B694,
    focus: 0xFFF2B694,
    outline: 0xFFA9B2B0,
    tool: 0xFFA7CFC2,
    code: 0xFFF1D589,
    error: 0xFFE5786B,
    added: 0xFF21422D,
    removed: 0xFF542424,
  );

  /// Black, greys and white. The default, and the phone app's.
  static const graphiteDark = AppPalette(
    primary: 0xFFE8E8E8,
    secondary: 0xFF8C8C8C,
    primaryContainer: 0xFF000000,
    secondaryContainer: 0xFF262626,
    accent: 0xFFFFFFFF,
    focus: 0xFFC4C4C4,
    outline: 0xFF4A4A4A,
    tool: 0xFFC4C4C4,
    code: 0xFFF2F2F2,
    error: 0xFFE5837A,
    added: 0xFF1B2D21,
    removed: 0xFF3A2120,
  );

  /// Graphite dark's greys on an off-white background.
  static const graphiteLight = AppPalette(
    primary: 0xFF1F1F1F,
    secondary: 0xFF6B6B6B,
    primaryContainer: 0xFFFAFAFA,
    secondaryContainer: 0xFFE8E8E8,
    accent: 0xFF000000,
    focus: 0xFF444444,
    outline: 0xFFC9C9C9,
    tool: 0xFF444444,
    code: 0xFF1A1A1A,
    error: 0xFFB3261E,
    added: 0xFFDCEFE0,
    removed: 0xFFF6DCDA,
  );
}

/// The themes /settings offers, each with its palette.
enum AppThemeMode {
  normal('Normal', AppPalette.normal),
  graphiteDark('Graphite dark', AppPalette.graphiteDark),
  graphiteLight('Graphite light', AppPalette.graphiteLight);

  const AppThemeMode(this.label, this.palette);

  final String label;
  final AppPalette palette;
}
