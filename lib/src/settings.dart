import 'dart:convert';
import 'dart:io';

import 'design_system/colors.dart';
import 'usage.dart';

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

/// Gemini's standard rates in dollars per million tokens, from
/// https://ai.google.dev/gemini-api/docs/pricing (November 2026). Thinking
/// tokens are billed as output.
const defaultPrices = {
  'gemini-3.1-flash-lite': Price(input: 0.25, cachedInput: 0.025, output: 1.5),
};

/// What the user picked in /settings, plus the price of each model, saved as
/// JSON so it survives a restart.
class Settings {
  const Settings({
    this.theme = AppThemeMode.graphiteDark,
    this.prices = defaultPrices,
  });

  final AppThemeMode theme;

  /// Dollars per million tokens, by model name. The header's spent counter
  /// uses these.
  final Map<String, Price> prices;

  /// Reads [file]. A missing, unreadable or unknown value falls back to the
  /// default. Prices in the file add to the defaults or replace them.
  factory Settings.load(File? file) {
    if (file == null || !file.existsSync()) return const Settings();

    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return const Settings();
      final theme = AppThemeMode.values.asNameMap()[json['theme']];
      final saved = json['prices'];
      return Settings(
        theme: theme ?? AppThemeMode.graphiteDark,
        prices: {
          ...defaultPrices,
          if (saved is Map)
            for (final MapEntry(:key, :value) in saved.entries)
              '$key': ?Price.fromJson(value),
        },
      );
    } on FormatException {
      return const Settings();
    }
  }

  Settings copyWith({AppThemeMode? theme}) =>
      Settings(theme: theme ?? this.theme, prices: prices);

  /// Writes to [file]. With no file, the settings last until the app quits.
  /// The prices are written too, so they can be edited there.
  void save(File? file) {
    if (file == null) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'theme': theme.name,
        'prices': {
          for (final MapEntry(:key, :value) in prices.entries)
            key: value.toJson(),
        },
      }),
    );
  }
}
