import 'dart:async';
import 'dart:io';

import 'package:coding_agent_in_dart/src/design_system/colors.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/settings.dart';
import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:coding_agent_in_dart/src/tui.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

class FakeProvider implements ModelProvider {
  FakeProvider(this.replies);

  final List<Message> replies;
  final systems = <String?>[];

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async {
    systems.add(system);
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
}
