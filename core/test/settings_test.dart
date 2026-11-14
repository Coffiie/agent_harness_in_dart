import 'dart:io';

import 'package:coding_agent_core/src/design_system/palette.dart';
import 'package:coding_agent_core/src/settings.dart';
import 'package:coding_agent_core/src/usage.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync());
  tearDown(() => dir.deleteSync(recursive: true));

  test('defaults to graphite dark without a file', () {
    expect(Settings.load(null).theme, AppThemeMode.graphiteDark);
    expect(
      Settings.load(File('${dir.path}/missing.json')).theme,
      AppThemeMode.graphiteDark,
    );
  });

  test('saves the theme and loads it back', () {
    final file = File('${dir.path}/nested/settings.json');

    const Settings(theme: AppThemeMode.graphiteLight).save(file);

    expect(Settings.load(file).theme, AppThemeMode.graphiteLight);
  });

  test("knows Gemini's price without a file", () {
    final price = Settings.load(null).prices['gemini-3.1-flash-lite']!;
    expect((price.input, price.cachedInput, price.output), (0.25, 0.025, 1.5));
  });

  test('prices in the file replace or add to the defaults', () {
    final file = File('${dir.path}/settings.json');
    file.writeAsStringSync('''
{
  "theme": "normal",
  "prices": {
    "gemini-3.1-flash-lite": {"input": 0.5, "output": 3},
    "other-model": {"input": 1, "output": 2},
    "broken": {"input": "free"}
  }
}''');

    final settings = Settings.load(file);

    expect(settings.theme, AppThemeMode.normal);
    expect(settings.prices['gemini-3.1-flash-lite']!.output, 3);
    expect(settings.prices['other-model']!.input, 1);
    expect(settings.prices.containsKey('broken'), isFalse);
  });

  test('saves the prices next to the theme so they can be edited', () {
    final file = File('${dir.path}/settings.json');
    const Settings(
      prices: {'m': Price(input: 2, output: 4)},
    ).copyWith(theme: AppThemeMode.graphiteLight).save(file);

    final loaded = Settings.load(file);

    expect(loaded.theme, AppThemeMode.graphiteLight);
    expect(loaded.prices['m']!.output, 4);
    expect(file.readAsStringSync(), contains('"prices"'));
  });

  test('falls back to the default for a broken or unknown file', () {
    final file = File('${dir.path}/settings.json');

    for (final content in ['not json', '[1, 2]', '{"theme": "neon"}']) {
      file.writeAsStringSync(content);
      expect(
        Settings.load(file).theme,
        AppThemeMode.graphiteDark,
        reason: content,
      );
    }
  });
}
