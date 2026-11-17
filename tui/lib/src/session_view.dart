import 'package:coding_agent_core/coding_agent_core.dart';
import 'package:nocterm/nocterm.dart';

/// What the TUI keeps for each session on top of core's [Session]: the
/// boxes typed into, and the transcript's scroll.
class SessionView {
  final input = TextEditingController();

  /// The answer typed under a question.
  final answerInput = TextEditingController();

  final scroll = AutoScrollController();

  void dispose() {
    input.dispose();
    answerInput.dispose();
    scroll.dispose();
  }
}

final _views = Expando<SessionView>('SessionView');

/// A session's [SessionView], made the first time the TUI asks for it.
extension SessionViewOf on Session {
  SessionView get view => _views[this] ??= SessionView();

  TextEditingController get input => view.input;
  TextEditingController get answerInput => view.answerInput;
  AutoScrollController get scroll => view.scroll;
}
