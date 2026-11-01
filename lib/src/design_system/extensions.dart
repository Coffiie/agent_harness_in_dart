import 'package:nocterm/nocterm.dart';

import 'theme.dart';

extension BuildContextExtended on BuildContext {
  AppTheme get theme => AppTheme.of(this);
}
