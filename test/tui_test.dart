import 'dart:io';

import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:coding_agent_in_dart/src/tui.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

class FakeProvider implements ModelProvider {
  FakeProvider(this.replies);

  final List<Message> replies;

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
  }) async => replies.removeAt(0);

  @override
  Future<int> countTokens(List<Message> messages) async => messages.length;
}

Message say(String text) => Message(Role.assistant, [TextPart(text)]);

void main() {
  test('shows the prompt and the reply', () async {
    await testNocterm('prompt and reply', (tester) async {
      await tester.pumpComponent(
        HarnessApp(provider: FakeProvider([say('Paris')]), model: 'fake'),
      );

      await tester.enterText('capital of France?');
      await tester.sendEnter();
      await tester.pump();

      expect(tester.terminalState, containsText('> capital of France?'));
      expect(tester.terminalState, containsText('Paris'));
    });
  });

  test('compacts the conversation on /compact', () async {
    await testNocterm('compact', (tester) async {
      await tester.pumpComponent(
        HarnessApp(
          provider: FakeProvider([say('hi'), say('summary')]),
          model: 'fake',
        ),
      );

      await tester.enterText('hello');
      await tester.sendEnter();
      await tester.pump();
      await tester.enterText('/compact');
      await tester.sendEnter();
      await tester.pump();

      expect(
        tester.terminalState,
        containsText('Compacted conversation from 2 tokens to 1 tokens'),
      );
    });
  });

  test('/clear empties the transcript', () async {
    await testNocterm('clear', (tester) async {
      await tester.pumpComponent(
        HarnessApp(provider: FakeProvider([say('hi')]), model: 'fake'),
      );

      await tester.enterText('hello');
      await tester.sendEnter();
      await tester.pump();
      await tester.enterText('/clear');
      await tester.sendEnter();
      await tester.pump();

      expect(tester.terminalState, isNot(containsText('> hello')));
    });
  });

  test('draws the diff of a file edit under the tool line', () async {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/a.txt';
    File(path).writeAsStringSync('one\ntwo\nthree\n');

    await testNocterm('diff', (tester) async {
      await tester.pumpComponent(
        HarnessApp(
          provider: FakeProvider([
            Message(Role.assistant, [
              ToolCall('updateFile', {
                'path': path,
                'content': 'one\n2\nthree\n',
              }),
            ]),
            say('done'),
          ]),
          model: 'fake',
        ),
      );

      await tester.enterText('edit it');
      await tester.sendEnter();
      await tester.pump();

      expect(tester.terminalState, containsText('┃ UpdateFile(path: '));
      expect(tester.terminalState, containsText('1   one'));
      expect(tester.terminalState, containsText('2 - two'));
      expect(tester.terminalState, containsText('2 + 2'));
      expect(tester.terminalState, containsText('3   three'));
      await tester.pump();
      expect(File(path).readAsStringSync(), 'one\n2\nthree\n');
    });
  });
}
