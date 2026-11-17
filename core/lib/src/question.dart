import 'dart:async';

import 'tools.dart';

/// Something the model asked the user with the askUser tool. Whoever
/// answers first wins: the TUI, or later the phone.
class Question {
  Question(this.text, this.options);

  final String text;

  /// The choices, the one the model recommends first.
  final List<String> options;

  final _answer = Completer<String>();

  /// Completes with the first answer.
  Future<String> get answer => _answer.future;

  bool get answered => _answer.isCompleted;

  /// The session that asked, set when the question also shows in another
  /// session, like a worker's in its orchestrator.
  String? asker;

  /// The answer, once there is one.
  String? get chosen => _chosen;
  String? _chosen;

  /// Answers the question. Returns false, and changes nothing, when it was
  /// already answered.
  bool reply(String choice) {
    if (answered) return false;
    _chosen = choice;
    _answer.complete(choice);
    return true;
  }

  /// A question from askUser's arguments, or null unless they have a
  /// question and at least one option.
  static Question? fromArgs(Map<String, dynamic> args) {
    final text = args['question'];
    final options = args['options'];
    if (text is! String || text.trim().isEmpty || options is! List) {
      return null;
    }
    final choices = [
      for (final option in options)
        if (option is String && option.trim().isNotEmpty) option.trim(),
    ];
    return choices.isEmpty ? null : Question(text.trim(), choices);
  }
}

/// Lets the model stop and ask the user to choose. The agent waits for the
/// answer and sends it back as the tool's result.
final askUserTool = Tool(
  name: 'askUser',
  description:
      'Ask the user to choose between options when you need a decision '
      'from them, instead of asking in a reply. Put the option you recommend '
      'first. The user picks one, or writes their own answer, and you get it '
      'back as the result.',
  parameters: {
    'type': 'object',
    'properties': {
      'question': {'type': 'string', 'description': 'the question'},
      'options': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'two to four short choices, the recommended one first',
      },
    },
    'required': ['question', 'options'],
  },
  label: (args) => 'AskUser',
  ask: Question.fromArgs,
  // only reached when the arguments make no question
  run: (args) async => {
    'error': 'askUser needs a question and at least one option',
  },
);
