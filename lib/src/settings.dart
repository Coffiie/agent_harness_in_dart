import 'dart:convert';
import 'dart:io';

import 'design_system/colors.dart';

enum AppThemeMode {
  normal('Normal'),
  graphiteDark('Graphite dark'),
  graphiteLight('Graphite light');

  const AppThemeMode(this.label);

  final String label;

  AppColorsTheme get colors => switch (this) {
    normal => AppColorsTheme.normal(),
    graphiteDark => AppColorsTheme.graphiteDark(),
    graphiteLight => AppColorsTheme.graphiteLight(),
  };
}

/// What the user picked in /settings, saved as JSON so it survives a restart.
class Settings {
  const Settings({this.theme = AppThemeMode.graphiteDark});

  final AppThemeMode theme;

  /// Reads [file]. A missing, unreadable or unknown value falls back to the
  /// default.
  factory Settings.load(File? file) {
    if (file == null || !file.existsSync()) return const Settings();

    try {
      final json = jsonDecode(file.readAsStringSync());
      final theme = json is Map
          ? AppThemeMode.values.asNameMap()[json['theme']]
          : null;
      return theme == null ? const Settings() : Settings(theme: theme);
    } on FormatException {
      return const Settings();
    }
  }

  /// Writes to [file]. With no file, the settings last until the app quits.
  void save(File? file) {
    if (file == null) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({'theme': theme.name}));
  }
}
