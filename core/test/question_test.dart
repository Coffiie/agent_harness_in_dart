import 'package:coding_agent_core/src/question.dart';
import 'package:test/test.dart';

void main() {
  test('the first answer wins', () async {
    final question = Question('Which?', ['a', 'b']);

    expect(question.reply('b'), isTrue);
    expect(question.reply('a'), isFalse);

    expect(await question.answer, 'b');
    expect(question.chosen, 'b');
    expect(question.answered, isTrue);
  });

  test('reads askUser arguments, trimming and dropping empty options', () {
    final question = Question.fromArgs({
      'question': ' Keep it? ',
      'options': [' Yes ', '', 3, 'No'],
    })!;

    expect(question.text, 'Keep it?');
    expect(question.options, ['Yes', 'No']);
  });

  test('makes no question without text or options', () {
    for (final args in <Map<String, dynamic>>[
      {},
      {'question': 'q'},
      {
        'question': '',
        'options': ['a'],
      },
      {'question': 'q', 'options': []},
      {'question': 'q', 'options': 'a'},
      {
        'question': 'q',
        'options': ['', ' '],
      },
    ]) {
      expect(Question.fromArgs(args), isNull, reason: '$args');
    }
  });

  test('askUser explains itself when the arguments make no question', () async {
    expect(askUserTool.ask!({}), isNull);
    expect(await askUserTool.run({}), contains('error'));
  });
}
