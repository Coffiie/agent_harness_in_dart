import 'dart:convert';
import 'dart:io';

import 'design_system/palette.dart';
import 'usage.dart';

/// Standard rates in dollars per million tokens, November 2026. Thinking
/// tokens are billed as output.
/// - Gemini: https://ai.google.dev/gemini-api/docs/pricing
/// - DeepSeek: https://api-docs.deepseek.com/quick_start/pricing, at its
///   peak rate. Off-peak hours cost half, so this is the most it costs.
/// - Kimi: https://platform.moonshot.ai/docs/pricing/chat
/// - OpenRouter's free models cost nothing.
const defaultPrices = {
  'gemini-3.1-flash-lite': Price(input: 0.25, cachedInput: 0.025, output: 1.5),
  'deepseek-flash': Price(input: 0.3, cachedInput: 0.006, output: 1.2),
  'deepseek-v4-pro': Price(input: 1.32, cachedInput: 0.044, output: 3.96),
  'kimi-k2.7-code': Price(input: 0.95, cachedInput: 0.19, output: 4),
  'nvidia/nemotron-3-ultra-550b-a55b:free': Price(input: 0, output: 0),
};

/// What the user picked in /settings, plus the price of each model, saved as
/// JSON so it survives a restart.
class Settings {
  const Settings({
    this.theme = AppThemeMode.graphiteDark,
    this.sandbox = false,
    this.prices = defaultPrices,
  });

  final AppThemeMode theme;

  /// Whether the agents' tools run in a Docker sandbox. Off by default, so
  /// the harness works on a computer without Docker.
  final bool sandbox;

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
        sandbox: json['sandbox'] == true,
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

  Settings copyWith({AppThemeMode? theme, bool? sandbox}) => Settings(
    theme: theme ?? this.theme,
    sandbox: sandbox ?? this.sandbox,
    prices: prices,
  );

  /// Writes to [file]. With no file, the settings last until the app quits.
  /// The prices are written too, so they can be edited there.
  void save(File? file) {
    if (file == null) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'theme': theme.name,
        'sandbox': sandbox,
        'prices': {
          for (final MapEntry(:key, :value) in prices.entries)
            key: value.toJson(),
        },
      }),
    );
  }
}
