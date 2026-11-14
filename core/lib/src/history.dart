import 'dart:io';

import 'diff.dart';

/// One file the agent wrote: what was there before, and what it wrote.
class Edit {
  const Edit(this.path, {required this.before, required this.after});

  final String path;

  /// The file's contents before the edit, or null when the edit created it.
  final String? before;
  final String after;
}

/// What /undo did to a file.
class Undo {
  const Undo(
    this.path, {
    this.diff = const [],
    this.deleted = false,
    this.changedSince = false,
    this.error,
  });

  final String path;

  /// From what was on disk to what /undo put back.
  final List<DiffLine> diff;

  /// The edit had created the file, so /undo deleted it.
  final bool deleted;

  /// The file changed after the edit, so /undo left it alone rather than
  /// lose those changes.
  final bool changedSince;

  final String? error;

  /// Whether the file is back to how it was before the edit.
  bool get undone => !changedSince && error == null;
}

/// The agent's file edits in one session, newest last, so /undo can take
/// them back one at a time.
class FileHistory {
  final _edits = <Edit>[];

  bool get isEmpty => _edits.isEmpty;

  void record(Edit edit) => _edits.add(edit);

  void clear() => _edits.clear();

  /// Puts back the file the last edit changed, and forgets that edit.
  /// Returns null when there is nothing to undo.
  Undo? undo() {
    if (_edits.isEmpty) return null;
    final edit = _edits.removeLast();
    final file = File(edit.path);

    try {
      final now = file.existsSync() ? file.readAsStringSync() : null;
      if (now != edit.after) return Undo(edit.path, changedSince: true);

      if (edit.before case final before?) {
        file.writeAsStringSync(before);
        return Undo(edit.path, diff: diffLines(edit.after, before));
      }
      file.deleteSync();
      return Undo(edit.path, diff: diffLines(edit.after, ''), deleted: true);
    } on FileSystemException catch (e) {
      return Undo(edit.path, error: e.message);
    }
  }
}
