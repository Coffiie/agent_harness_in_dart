import 'dart:io';

import 'package:coding_agent_in_dart/src/settings.dart';
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
