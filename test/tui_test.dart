import 'dart:async';
import 'dart:io';

import 'package:coding_agent_in_dart/src/design_system/colors.dart';
import 'package:coding_agent_in_dart/src/history.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/question.dart';
import 'package:coding_agent_in_dart/src/settings.dart';
import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:coding_agent_in_dart/src/tui.dart';
import 'package:coding_agent_in_dart/src/usage.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

class FakeProvider implements ModelProvider {
  FakeProvider(this.replies);

  final List<Message> replies;
  final systems = <String?>[];
  final requests = <List<Message>>[];

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async {
    systems.add(system);
    requests.add(List.of(messages));
    return replies.removeAt(0);
  }

  @override
  Future<int> countTokens(List<Message> messages) async => messages.length;
}

Message say(String text) => Message(Role.assistant, [TextPart(text)]);

/// Holds every reply until the test completes [reply], so the test can look
/// at the screen while the agent works.
class HeldProvider implements ModelProvider {
  final reply = Completer<Message>();

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) => reply.future;

  @override
  Future<int> countTokens(List<Message> messages) async => messages.length;
}

class FailingProvider implements ModelProvider {
  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async => throw Exception('503 high demand');

  @override
  Future<int> countTokens(List<Message> messages) async => messages.length;
}

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

  test('tells the model the diff is already on screen', () async {
    final provider = FakeProvider([say('hi')]);

    await testNocterm('system prompt', (tester) async {
      await tester.pumpComponent(HarnessApp(provider: provider, model: 'fake'));

      await tester.enterText('hello');
      await tester.sendEnter();
      await tester.pump();
    });

    expect(provider.systems, [systemPrompt]);
    expect(systemPrompt, contains('Never write a diff'));
  });

  group('Term', () {
    test('waits in the header before the first prompt', () async {
      await testNocterm('term waiting', (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'fake'),
        );

        expect(tester.terminalState, containsText('▛▀▀▀▀▜'));
        expect(tester.terminalState, containsText('▙ >_ ▟'));
      });
    });

    test('works while the agent runs, then shows it is done', () async {
      final provider = HeldProvider();

      await testNocterm('term working', (tester) async {
        await tester.pumpComponent(HarnessApp(provider: provider, model: 'f'));

        await tester.enterText('hello');
        await tester.sendEnter();
        await tester.pump();

        expect(tester.terminalState, containsText('▙ ▘▘ ▟'));
        expect(tester.terminalState, containsText('▘▘ Thinking…'));

        provider.reply.complete(say('hi'));
        await Future<void>.delayed(Duration.zero);
        await tester.pump();

        expect(tester.terminalState, containsText('▙ ^^ ▟'));
        expect(tester.terminalState, isNot(containsText('Thinking…')));
      });
    });

    test(
      'shows the error face in the error color after a failed turn',
      () async {
        await testNocterm('term error', (tester) async {
          await tester.pumpComponent(
            HarnessApp(provider: FailingProvider(), model: 'fake'),
          );

          await tester.enterText('hello');
          await tester.sendEnter();
          await tester.pump();

          final eyes = tester.terminalState.findText('××').first;
          expect(
            tester.terminalState.getCellAt(eyes.x, eyes.y)!.style.color,
            AppColorsTheme.graphiteDark().error,
          );
        });
      },
    );

    test('/clear sends it back to waiting', () async {
      await testNocterm('term clear', (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([say('hi')]), model: 'fake'),
        );

        await tester.enterText('hello');
        await tester.sendEnter();
        await tester.pump();
        expect(tester.terminalState, containsText('▙ ^^ ▟'));

        await tester.enterText('/clear');
        await tester.sendEnter();
        await tester.pump();
        expect(tester.terminalState, containsText('▙ >_ ▟'));
      });
    });
  });

  group('askUser', () {
    Message ask(String question, List<String> options) =>
        Message(Role.assistant, [
          ToolCall('askUser', {'question': question, 'options': options}),
        ]);

    Object? answerSent(FakeProvider provider) =>
        (provider.requests.last.last.parts.single as ToolResult)
            .output['answer'];

    Future<void> askAndWait(NoctermTester tester) async {
      await tester.enterText('add tests');
      await tester.sendEnter();
      await tester.pump();
    }

    test('shows the choices, the recommended one first and selected', () async {
      final provider = FakeProvider([
        ask('Also test 0 and 1 disks?', ['Yes, add the edge cases', 'No']),
        say('ok'),
      ]);

      await testNocterm('ask shows', (tester) async {
        await tester.pumpComponent(HarnessApp(provider: provider, model: 'f'));
        await askAndWait(tester);

        expect(tester.terminalState, containsText('┃ AskUser'));
        expect(
          tester.terminalState,
          containsText('? Also test 0 and 1 disks?'),
        );
        expect(
          tester.terminalState,
          containsText('❯ 1. Yes, add the edge cases (recommended)'),
        );
        expect(tester.terminalState, containsText('2. No'));
        expect(tester.terminalState, containsText('3. Something else…'));
        expect(tester.terminalState, containsText('▙ ?? ▟'));
        expect(tester.terminalState, isNot(containsText('Thinking…')));
        expect(provider.requests, hasLength(1));
      });
    });

    test('Enter takes the recommended answer and the turn goes on', () async {
      final provider = FakeProvider([
        ask('Edge cases?', ['Yes', 'No']),
        say('Added them.'),
      ]);

      await testNocterm('ask enter', (tester) async {
        await tester.pumpComponent(HarnessApp(provider: provider, model: 'f'));
        await askAndWait(tester);

        await tester.sendEnter();
        await tester.pump();
        await tester.pump();

        expect(answerSent(provider), 'Yes');
        expect(tester.terminalState, containsText('✓ Yes'));
        expect(tester.terminalState, containsText('Added them.'));
        expect(tester.terminalState, containsText('▙ ^^ ▟'));
      });
    });

    test('the arrow keys or a number pick another', () async {
      final arrows = FakeProvider([
        ask('Q?', ['a', 'b', 'c']),
        say('ok'),
      ]);
      final number = FakeProvider([
        ask('Q?', ['a', 'b', 'c']),
        say('ok'),
      ]);

      await testNocterm('ask arrows', (tester) async {
        await tester.pumpComponent(HarnessApp(provider: arrows, model: 'f'));
        await askAndWait(tester);
        await tester.sendArrowDown();
        await tester.sendArrowDown();
        await tester.sendEnter();
        await tester.pump();
        await tester.pump();
      });
      await testNocterm('ask number', (tester) async {
        await tester.pumpComponent(HarnessApp(provider: number, model: 'f'));
        await askAndWait(tester);
        await tester.enterText('2');
        await tester.pump();
        await tester.pump();
      });

      expect(answerSent(arrows), 'c');
      expect(answerSent(number), 'b');
    });

    test('"Something else" takes a typed answer', () async {
      final provider = FakeProvider([
        ask('Q?', ['a', 'b']),
        say('ok'),
      ]);

      await testNocterm('ask typed', (tester) async {
        await tester.pumpComponent(HarnessApp(provider: provider, model: 'f'));
        await askAndWait(tester);
        await tester.enterText('3');
        await tester.pump();
        expect(tester.terminalState, containsText('Type your answer'));

        await tester.enterText('only the 3 disk case');
        await tester.sendEnter();
        await tester.pump();
        await tester.pump();

        expect(answerSent(provider), 'only the 3 disk case');
        expect(tester.terminalState, containsText('✓ only the 3 disk case'));
      });
    });

    test('an answer from elsewhere closes the picker', () async {
      final provider = FakeProvider([
        ask('Q?', ['a', 'b']),
        say('ok'),
      ]);
      Question? asked;

      await testNocterm('ask elsewhere', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: provider,
            model: 'f',
            onQuestion: (question) => asked = question,
          ),
        );
        await askAndWait(tester);

        asked!.reply('b');
        await tester.pump();
        await tester.pump();

        expect(answerSent(provider), 'b');
        expect(tester.terminalState, containsText('✓ b'));
        expect(tester.terminalState, containsText('Ask anything'));
      });
    });
  });

  group('/undo', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    Message update(String path, String content) => Message(Role.assistant, [
      ToolCall('updateFile', {'path': path, 'content': content}),
    ]);

    test('puts the file back, shows the diff and tells the model', () async {
      final path = '${dir.path}/a.txt';
      File(path).writeAsStringSync('one\ntwo\n');
      final provider = FakeProvider([
        update(path, 'one\n2\n'),
        say('changed'),
        say('ok'),
      ]);

      await testNocterm('undo', (tester) async {
        await tester.pumpComponent(HarnessApp(provider: provider, model: 'f'));

        await tester.enterText('edit it');
        await tester.sendEnter();
        await tester.pump();
        await tester.pump();
        expect(File(path).readAsStringSync(), 'one\n2\n');

        await tester.enterText('/undo');
        await tester.sendEnter();
        await tester.pump();

        expect(File(path).readAsStringSync(), 'one\ntwo\n');
        expect(tester.terminalState, containsText('↺ Undid UpdateFile(path: '));
        expect(tester.terminalState, containsText('2 - 2'));
        expect(tester.terminalState, containsText('2 + two'));
        expect(
          tester.terminalState,
          containsText('The model was told this edit was undone.'),
        );
        expect(tester.terminalState, containsText('▙ << ▟'));

        await tester.enterText('next');
        await tester.sendEnter();
        await tester.pump();
      });

      final sent = provider.requests.last.last.parts;
      expect((sent.first as TextPart).text, undoNote(Undo(path)));
      expect((sent.last as TextPart).text, 'next');
    });

    test('deletes a file the agent created', () async {
      final path = '${dir.path}/new.txt';

      await testNocterm('undo created', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([update(path, 'x\n'), say('made it')]),
            model: 'f',
          ),
        );

        await tester.enterText('make a file');
        await tester.sendEnter();
        await tester.pump();
        await tester.pump();
        await tester.enterText('/undo');
        await tester.sendEnter();
        await tester.pump();

        expect(File(path).existsSync(), isFalse);
        expect(
          tester.terminalState,
          containsText('That edit created the file, so it is deleted.'),
        );
      });
    });

    test('says so when there is nothing to undo', () async {
      await testNocterm('undo nothing', (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'f'),
        );

        await tester.enterText('/undo');
        await tester.sendEnter();
        await tester.pump();

        expect(tester.terminalState, containsText('┃ Nothing to undo.'));
        expect(tester.terminalState, containsText('▙ >_ ▟'));
      });
    });

    test('/clear starts over with nothing to undo', () async {
      final path = '${dir.path}/a.txt';
      File(path).writeAsStringSync('old');

      await testNocterm('undo after clear', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([update(path, 'new'), say('ok')]),
            model: 'f',
          ),
        );

        await tester.enterText('edit');
        await tester.sendEnter();
        await tester.pump();
        await tester.pump();
        await tester.enterText('/clear');
        await tester.sendEnter();
        await tester.pump();
        await tester.enterText('/undo');
        await tester.sendEnter();
        await tester.pump();

        expect(tester.terminalState, containsText('┃ Nothing to undo.'));
        expect(File(path).readAsStringSync(), 'new');
      });
    });
  });

  group('cost', () {
    late File file;

    setUp(() {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      file = File('${dir.path}/settings.json');
      // $1 per million input tokens and $2 per million output, so the
      // numbers are easy to check
      const Settings(prices: {'fake': Price(input: 1, output: 2)}).save(file);
    });

    Message costing(String text, int input, int output) => Message(
      Role.assistant,
      [TextPart(text)],
      usage: Usage(input: input, output: output),
    );

    test('starts at zero', () async {
      await testNocterm('cost zero', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        expect(tester.terminalState, containsText('context 0 tok'));
        expect(tester.terminalState, containsText(r'spent $0.0000'));
      });
    });

    test('shows the chat size and adds up what each call cost', () async {
      await testNocterm('cost adds up', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([
              costing('one', 1000, 200),
              costing('two', 3000, 318),
            ]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        await tester.enterText('first');
        await tester.sendEnter();
        await tester.pump();
        expect(tester.terminalState, containsText('context 1,200 tok'));
        expect(tester.terminalState, containsText(r'spent $0.0014'));

        await tester.enterText('second');
        await tester.sendEnter();
        await tester.pump();
        // 1000 + 3000 input at $1, 200 + 318 output at $2
        expect(tester.terminalState, containsText('context 3,318 tok'));
        expect(tester.terminalState, containsText(r'spent $0.0050'));
      });
    });

    test('/compact shrinks the context but not what was spent', () async {
      await testNocterm('cost compact', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([
              costing('hi', 3000, 318),
              costing('summary', 3318, 100),
            ]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        await tester.enterText('hello');
        await tester.sendEnter();
        await tester.pump();
        await tester.enterText('/compact');
        await tester.sendEnter();
        await tester.pump();

        // the fake counts one token per message, and the summary is one
        expect(tester.terminalState, containsText('context 1 tok'));
        expect(tester.terminalState, containsText(r'spent $0.0072'));
      });
    });

    test('/clear empties the context and keeps what was spent', () async {
      await testNocterm('cost clear', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([costing('hi', 3000, 318)]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        await tester.enterText('hello');
        await tester.sendEnter();
        await tester.pump();
        await tester.enterText('/clear');
        await tester.sendEnter();
        await tester.pump();

        expect(tester.terminalState, containsText('context 0 tok'));
        expect(tester.terminalState, containsText(r'spent $0.0036'));
      });
    });

    test('says so when the model has no price', () async {
      await testNocterm('cost no price', (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'mystery'),
        );

        expect(tester.terminalState, containsText('no price for mystery'));
      });
    });

    test('changing the theme keeps the prices', () async {
      await testNocterm('cost theme', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        await tester.enterText('/settings');
        await tester.sendEnter();
        await tester.pump();
        await tester.sendArrowDown();
        await tester.sendEnter();
        await tester.pump();

        expect(Settings.load(file).prices['fake']!.output, 2);
        expect(tester.terminalState, containsText(r'spent $0.0000'));
      });
    });
  });

  group('settings', () {
    late File file;

    setUp(() {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      file = File('${dir.path}/settings.json');
    });

    test('switches the theme from /settings and saves it', () async {
      await testNocterm('switch theme', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        await tester.enterText('/settings');
        await tester.sendEnter();
        await tester.pump();
        expect(tester.terminalState, containsText('Graphite dark (current)'));

        await tester.sendArrowDown();
        await tester.sendEnter();
        await tester.pump();

        expect(tester.terminalState, isNot(containsText('Settings')));
        expect(Settings.load(file).theme, AppThemeMode.graphiteLight);
        expect(
          tester.terminalState.getCellAt(0, 0)!.style.backgroundColor,
          AppColorsTheme.graphiteLight().primaryContainer,
        );
      });
    });

    test('esc closes /settings without changing the theme', () async {
      await testNocterm('esc', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        await tester.enterText('/settings');
        await tester.sendEnter();
        await tester.pump();
        await tester.sendArrowDown();
        await tester.sendEscape();
        await tester.pump();

        expect(tester.terminalState, isNot(containsText('Settings')));
        expect(file.existsSync(), isFalse);
      });
    });

    test('starts with the saved theme', () async {
      const Settings(theme: AppThemeMode.normal).save(file);

      await testNocterm('saved theme', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        final title = tester.terminalState.findText('coding_agent_in_dart');
        expect(
          tester.terminalState
              .getCellAt(title.first.x, title.first.y)!
              .style
              .color,
          AppColorsTheme.normal().accent,
        );
      });
    });

    test('gives unstyled reply text the light theme text color', () async {
      // nocterm's markdown leaves list items without a color, so without
      // the theme's foreground they would be the terminal's white on white.
      const Settings(theme: AppThemeMode.graphiteLight).save(file);

      await testNocterm('light list', (tester) async {
        await tester.pumpComponent(
          HarnessApp(
            provider: FakeProvider([say('- item one')]),
            model: 'fake',
            settingsFile: file,
          ),
        );

        await tester.enterText('list');
        await tester.sendEnter();
        await tester.pump();

        final item = tester.terminalState.findText('item one').first;
        expect(
          tester.terminalState.getCellAt(item.x, item.y)!.style.color,
          AppColorsTheme.graphiteLight().primary,
        );
      });
    });
  });

  group('sessions', () {
    const wide = Size(120, 30);

    Future<void> type(NoctermTester tester, String text) async {
      await tester.enterText(text);
      await tester.sendEnter();
      await tester.pump();
    }

    Future<void> ctrlTab(NoctermTester tester, {bool shift = false}) =>
        tester.sendKeyEvent(
          KeyboardEvent(
            logicalKey: LogicalKey.tab,
            modifiers: ModifierKeys(ctrl: true, shift: shift),
          ),
        );

    Future<void> mouse(
      NoctermTester tester,
      int x,
      int y, {
      bool pressed = true,
      bool moving = false,
    }) => tester.sendMouseEvent(
      MouseEvent(
        button: MouseButton.left,
        x: x,
        y: y,
        pressed: pressed,
        isMotion: moving,
      ),
    );

    Future<void> click(NoctermTester tester, int x, int y) async {
      await mouse(tester, x, y);
      await mouse(tester, x, y, pressed: false);
    }

    Future<void> drag(
      NoctermTester tester,
      TextMatch from,
      int x,
      int y,
    ) async {
      await mouse(tester, from.x, from.y);
      await mouse(tester, x, y, moving: true);
      await mouse(tester, x, y, pressed: false);
    }

    // the name on the sidebar row marked ▸
    String active(NoctermTester tester) {
      final mark = tester.terminalState.findText('▸ ').single;
      return tester.terminalState
          .getTextAt(mark.x + 5, mark.y, length: 20)!
          .split(' · ')
          .first;
    }

    test('shows no sidebar until there is a second session', () async {
      await testNocterm('sidebar', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'fake'),
        );
        expect(tester.terminalState, isNot(containsText('Sessions')));

        await type(tester, '/new');

        expect(tester.terminalState, containsText('Sessions'));
        expect(tester.terminalState, containsText('>_ session 1 · idle'));
        expect(tester.terminalState, containsText('>_ session 2 · idle'));
        expect(active(tester), 'session 2');
      });
    });

    test('names a session after its first prompt', () async {
      await testNocterm('name', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([say('ok')]), model: 'fake'),
        );

        await type(tester, 'write a tower of hanoi algorithm');
        await type(tester, '/new');

        expect(tester.terminalState, containsText('^^ tower hanoi · done'));
      });
    });

    test('/fork copies the chat into a new session next to it', () async {
      final provider = FakeProvider([say('Paris'), say('Lyon')]);

      await testNocterm('fork', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: provider, model: 'fake'),
        );

        await type(tester, 'capital of France?');
        await type(tester, '/fork');

        expect(active(tester), 'capital France 2');
        expect(tester.terminalState, containsText('> capital of France?'));
        expect(tester.terminalState, containsText('Paris'));
        expect(
          tester.terminalState,
          containsText('Forked from capital France'),
        );

        await type(tester, 'and the second city?');
        expect(provider.requests.last, hasLength(3)); // the chat came along
        expect(tester.terminalState, containsText('Lyon'));

        await ctrlTab(tester, shift: true);
        expect(active(tester), 'capital France');
        expect(tester.terminalState, isNot(containsText('Lyon')));
      });
    });

    test('Ctrl+Tab, Shift+Tab and Ctrl+Shift+Tab switch sessions', () async {
      await testNocterm('switch', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'fake'),
        );
        await type(tester, '/new');
        await type(tester, '/new');
        expect(active(tester), 'session 3');

        await ctrlTab(tester);
        expect(active(tester), 'session 1');

        await tester.sendKeyEvent(
          KeyboardEvent(
            logicalKey: LogicalKey.tab,
            modifiers: const ModifierKeys(shift: true),
          ),
        );
        expect(active(tester), 'session 2');

        await ctrlTab(tester, shift: true);
        expect(active(tester), 'session 1');
      });
    });

    test('clicking a row switches to it', () async {
      await testNocterm('click row', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'fake'),
        );
        await type(tester, '/new');

        final row = tester.terminalState.findText('session 1').first;
        await click(tester, row.x, row.y);

        expect(active(tester), 'session 1');
      });
    });

    test('a session keeps working while another has the screen', () async {
      final provider = HeldProvider();

      await testNocterm('background', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: provider, model: 'fake'),
        );

        await type(tester, 'hello');
        await type(tester, '/new'); // works while hello is busy
        expect(active(tester), 'session 2');
        expect(tester.terminalState, containsText('hello · working'));

        provider.reply.complete(say('Bonjour'));
        await Future<void>.delayed(Duration.zero);
        await tester.pump();

        expect(tester.terminalState, containsText('^^ hello · done'));
        expect(tester.terminalState, isNot(containsText('Bonjour')));
      });
    });

    test(
      '/new with a prompt starts fresh when Gemini says it needs nothing',
      () async {
        final provider = FakeProvider([say('Paris'), say('NONE'), say('Done')]);

        await testNocterm('new fresh', size: wide, (tester) async {
          await tester.pumpComponent(
            HarnessApp(provider: provider, model: 'fake'),
          );

          await type(tester, 'capital of France?');
          await type(tester, '/new write a haiku');
          await tester.pump();

          expect(active(tester), 'haiku');
          expect(
            tester.terminalState,
            containsText("Gemini says this doesn't need capital France"),
          );
          expect(tester.terminalState, containsText('Done'));
          expect(provider.requests[1], hasLength(3)); // the question
          expect(provider.requests[2], hasLength(1)); // the prompt alone
        });
      },
    );

    test('/new with a prompt carries a summary when Gemini says so', () async {
      final provider = FakeProvider([
        say('Paris'),
        say('[CompactedSummaryFromModel]\n- The capital of France is Paris.'),
        say('Lyon'),
      ]);

      await testNocterm('new carried', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: provider, model: 'fake'),
        );

        await type(tester, 'capital of France?');
        await type(tester, '/new and the second city?');
        await tester.pump();

        expect(active(tester), 'second city');
        expect(tester.terminalState, containsText('so a summary of it came'));
        expect(
          tester.terminalState,
          containsText('- The capital of France is Paris.'),
        );
        expect(tester.terminalState, containsText('Lyon'));
        final sent = provider.requests[2];
        expect(sent, hasLength(2)); // the summary, then the prompt
        expect((sent.first.parts.single as TextPart).text, contains('Paris'));
      });
    });

    test(
      '/new with a prompt from an empty session makes no extra call',
      () async {
        final provider = FakeProvider([say('hi')]);

        await testNocterm('new empty', size: wide, (tester) async {
          await tester.pumpComponent(
            HarnessApp(provider: provider, model: 'fake'),
          );

          await type(tester, '/new hello there');
          await tester.pump();

          expect(
            tester.terminalState,
            containsText('session 1 has no chat yet, so this starts fresh.'),
          );
          expect(provider.requests, hasLength(1));
        });
      },
    );

    test(
      'dragging a session in splits the screen, and out unsplits it',
      () async {
        final provider = FakeProvider([say('Paris'), say('Rome'), say('Lyon')]);

        await testNocterm('split', size: wide, (tester) async {
          await tester.pumpComponent(
            HarnessApp(provider: provider, model: 'fake'),
          );
          await type(tester, 'capital of France?');
          await type(tester, '/new');
          await type(tester, 'capital of Italy?');
          expect(tester.terminalState, isNot(containsText('Paris')));

          final row = tester.terminalState.findText('capital France').first;
          await drag(tester, row, 80, 12);

          expect(tester.terminalState, containsText('Paris'));
          expect(tester.terminalState, containsText('Rome'));
          expect(active(tester), 'capital Italy');

          // clicking the France pane gives it the keyboard
          final paris = tester.terminalState.findText('Paris').single;
          await click(tester, paris.x, paris.y);
          expect(active(tester), 'capital France');
          await type(tester, 'second city?');
          expect(provider.requests.last, hasLength(3));

          // drag the France pane by its title back to the sidebar
          final title = tester.terminalState
              .findText('capital France')
              .firstWhere((m) => m.x > 36);
          await drag(tester, title, 5, 20);

          expect(tester.terminalState, isNot(containsText('Lyon')));
          expect(tester.terminalState, containsText('Rome'));
          expect(active(tester), 'capital Italy');
        });
      },
    );

    test('a third session goes below the first two', () async {
      await testNocterm('three panes', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'fake'),
        );
        await type(tester, '/new');
        await type(tester, '/new');

        await drag(
          tester,
          tester.terminalState.findText('session 1').first,
          80,
          12,
        );
        await drag(
          tester,
          tester.terminalState.findText('session 2').first,
          80,
          25,
        );

        // each pane's title has its name, next to the sidebar's three rows
        for (final name in ['session 1', 'session 2', 'session 3']) {
          expect(tester.terminalState.findText(name), hasLength(2));
        }
        final third = tester.terminalState
            .findText('session 2')
            .firstWhere((m) => m.x > 36);
        expect(third.y, 15); // the bottom row starts half way down
      });
    });

    test("each session types into its own input", () async {
      // nocterm's TextField keeps the first controller it was given, so a
      // session drawn where another was would type into the other's input
      await testNocterm('fresh input', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([say('hi')]), model: 'fake'),
        );

        await type(tester, '/new');
        await type(tester, '/new');
        await type(tester, '/new hello there');
        await tester.pump();

        expect(tester.terminalState, containsText('> hello there'));
        expect(tester.terminalState, isNot(containsText('/new hello')));
      });
    });

    test('« folds the sidebar into a rail, and » brings it back', () async {
      await testNocterm('fold', size: wide, (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'fake'),
        );
        await type(tester, '/new');

        final fold = tester.terminalState.findText('«').single;
        await click(tester, fold.x, fold.y);
        expect(tester.terminalState, isNot(containsText('Sessions')));
        expect(tester.terminalState, containsText('▸>_'));

        final unfold = tester.terminalState.findText('»').single;
        await click(tester, unfold.x, unfold.y);
        expect(tester.terminalState, containsText('Sessions'));
      });
    });

    test('a narrow terminal shows the rail', () async {
      await testNocterm('narrow', (tester) async {
        await tester.pumpComponent(
          HarnessApp(provider: FakeProvider([]), model: 'fake'),
        );
        await type(tester, '/new');

        expect(tester.terminalState, containsText('»'));
        expect(tester.terminalState, isNot(containsText('Sessions')));
      });
    });
  });
}
