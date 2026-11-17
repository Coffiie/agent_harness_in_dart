import 'dart:convert';
import 'dart:math';

enum Change { same, added, removed, skipped }

class DiffLine {
  const DiffLine(this.change, this.text, [this.number = 0]);

  final Change change;
  final String text;

  /// The line number in the new file, or in the old file for a removed line.
  final int number;

  @override
  String toString() => switch (change) {
    Change.same => '$number   $text',
    Change.added => '$number + $text',
    Change.removed => '$number - $text',
    Change.skipped => '⋮',
  };
}

/// The lines that change when [before] becomes [after], with [context]
/// unchanged lines around each change. Unchanged lines further away are
/// hidden, and each hidden run becomes one [Change.skipped] line.
List<DiffLine> diffLines(String before, String after, {int context = 2}) {
  final a = LineSplitter.split(before).toList();
  final b = LineSplitter.split(after).toList();
  if (a.length * b.length > 4000000) return const [];

  // lcs[i][j]: how many lines a[i..] and b[j..] have in common, in order.
  final lcs = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }

  final lines = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] == b[j]) {
      lines.add(DiffLine(Change.same, b[j], j + 1));
      i++;
      j++;
    } else if (i < a.length &&
        (j == b.length || lcs[i + 1][j] >= lcs[i][j + 1])) {
      lines.add(DiffLine(Change.removed, a[i], i + 1));
      i++;
    } else {
      lines.add(DiffLine(Change.added, b[j], j + 1));
      j++;
    }
  }

  return _aroundChanges(lines, context);
}

List<DiffLine> _aroundChanges(List<DiffLine> lines, int context) {
  bool nearChange(int k) => lines
      .sublist(max(0, k - context), min(lines.length, k + context + 1))
      .any((line) => line.change != Change.same);

  final shown = <DiffLine>[];
  var hidden = false;
  for (var k = 0; k < lines.length; k++) {
    if (!nearChange(k)) {
      hidden = true;
      continue;
    }
    if (hidden && shown.isNotEmpty) {
      shown.add(const DiffLine(Change.skipped, ''));
    }
    hidden = false;
    shown.add(lines[k]);
  }
  return shown;
}
