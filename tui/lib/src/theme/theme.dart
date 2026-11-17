import 'package:nocterm/nocterm.dart';

import 'colors.dart';

/// Hands the active theme to every component below it, the way Flutter's
/// `Theme` does.
class AppTheme extends InheritedComponent {
  const AppTheme({super.key, required this.colors, required super.child});

  final AppColorsTheme colors;

  static AppTheme of(BuildContext context) =>
      context.dependOnInheritedComponentOfExactType<AppTheme>()!;

  @override
  bool updateShouldNotify(AppTheme oldComponent) =>
      colors != oldComponent.colors;
}
