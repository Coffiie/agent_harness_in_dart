import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_phone/link.dart';
import 'package:harness_phone/main.dart';

/// A TUI on the other end: what it sends the app, and what the app sent it.
class FakeTui {
  // sync, so a message has arrived before the next pump draws it
  final _messages = StreamController<dynamic>(sync: true);
  final sent = <Map<String, dynamic>>[];

  late final link = Link(
    _messages.stream,
    (text) => sent.add(jsonDecode(text)),
  );

  void send(Map<String, dynamic> message) => _messages.add(jsonEncode(message));

  void close() => _messages.close();

  void sessions(List<Map<String, dynamic>> list) =>
      send({'type': 'sessions', 'sessions': list});

  void entries(int session, int from, List<Map<String, dynamic>> entries) =>
      send({
        'type': 'entries',
        'session': session,
        'from': from,
        'reset': from == 0,
        'entries': entries,
      });
}

Map<String, dynamic> info(
  int id,
  String name, {
  String status = 'idle',
  String mood = 'waiting',
  bool busy = false,
  String? spent,
}) => {
  'id': id,
  'name': name,
  'status': status,
  'mood': mood,
  'busy': busy,
  'spent': spent,
};

void main() {
  late FakeTui tui;

  Future<void> connect(WidgetTester tester) async {
    // made here, inside the test's fake clock, so its messages arrive
    tui = FakeTui();
    await tester.pumpWidget(HarnessPhone(connect: (_, _) async => tui.link));
    await tester.enterText(find.byKey(const Key('address')), '192.168.1.2');
    await tester.enterText(find.byKey(const Key('code')), '123456');
    await tester.tap(find.byKey(const Key('connect')));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, int id) async {
    await tester.tap(find.byKey(Key('session $id')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('says so when it cannot connect', (tester) async {
    await tester.pumpWidget(
      HarnessPhone(connect: (_, _) => Future.error(Exception('refused'))),
    );
    await tester.tap(find.byKey(const Key('connect')));
    await tester.pump();

    expect(find.textContaining("Couldn't connect"), findsOneWidget);
  });

  testWidgets('lists the sessions with their status and spending', (
    tester,
  ) async {
    await connect(tester);
    tui.sessions([
      info(1, 'tower hanoi', status: 'done', mood: 'done', spent: r'$0.0012'),
      info(2, 'test function', status: 'working', mood: 'working', busy: true),
    ]);
    await tester.pump();

    expect(find.text('tower hanoi'), findsOneWidget);
    expect(find.text(r'done · $0.0012'), findsOneWidget);
    expect(find.text('test function'), findsOneWidget);
    expect(find.text('working'), findsOneWidget);
    expect(find.text('^^'), findsOneWidget);
  });

  testWidgets('shows a transcript and sends a prompt to that session', (
    tester,
  ) async {
    await connect(tester);
    tui.sessions([info(1, 'session 1'), info(2, 'readme')]);
    tui.entries(2, 0, [
      {'kind': 'prompt', 'text': 'write a readme', 'fromPhone': false},
      {
        'kind': 'tool',
        'label': 'UpdateFile(path: README.md)',
        'diff': [
          {'n': 1, 'change': 'added', 'text': '# Hanoi'},
        ],
      },
      {'kind': 'usage'},
      {'kind': 'reply', 'text': 'Wrote README.md.'},
    ]);
    await tester.pump();
    await open(tester, 2);

    expect(find.text('> write a readme'), findsOneWidget);
    expect(find.text('┃ UpdateFile(path: README.md)'), findsOneWidget);
    expect(find.text('1 + # Hanoi'), findsOneWidget);
    expect(find.text('Wrote README.md.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('prompt')), 'add a license');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();

    expect(tui.sent, [
      {'type': 'prompt', 'session': 2, 'text': 'add a license'},
    ]);
    // the keyboard goes away, so the transcript has the screen
    final box = find.descendant(
      of: find.byKey(const Key('prompt')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(box).focusNode.hasFocus, isFalse);
  });

  testWidgets('new entries add on, and /clear starts over', (tester) async {
    await connect(tester);
    tui.sessions([info(1, 'session 1')]);
    tui.entries(1, 0, [
      {'kind': 'prompt', 'text': 'hello', 'fromPhone': true},
    ]);
    tui.entries(1, 1, [
      {'kind': 'reply', 'text': 'Hi there'},
    ]);
    await tester.pump();
    await open(tester, 1);

    expect(find.text('> hello'), findsOneWidget);
    expect(find.text(' from phone'), findsOneWidget);
    expect(find.text('Hi there'), findsOneWidget);

    tui.entries(1, 0, []);
    await tester.pump();
    expect(find.text('> hello'), findsNothing);
  });

  testWidgets('a busy session cannot be sent a prompt', (tester) async {
    await connect(tester);
    tui.sessions([info(1, 'session 1', busy: true, mood: 'working')]);
    await tester.pump();
    await open(tester, 1);

    expect(find.text('Term is working…'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('prompt')), 'hello');
    await tester.tap(find.byKey(const Key('send')));
    expect(tui.sent, isEmpty);
  });

  group('a question', () {
    Future<void> ask(WidgetTester tester) async {
      await connect(tester);
      tui.sessions([info(1, 'session 1', status: 'needs you', mood: 'needs')]);
      tui.entries(1, 0, [
        {
          'kind': 'question',
          'id': 7,
          'text': 'Print or return?',
          'options': ['Return', 'Print'],
          'chosen': null,
        },
      ]);
      await tester.pump();
      await open(tester, 1);
    }

    testWidgets('has the recommended answer first, labelled and picked', (
      tester,
    ) async {
      await ask(tester);

      expect(find.text('? Print or return?'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      final first = find.byKey(const Key('option 0'));
      expect(
        find.descendant(of: first, matching: find.text('Recommended')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: first, matching: find.text('● ')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('answer')));
      expect(tui.sent.single, {
        'type': 'answer',
        'question': 7,
        'choice': 'Return',
      });
    });

    testWidgets('sends another option, or your own answer', (tester) async {
      await ask(tester);

      await tester.tap(find.byKey(const Key('option 1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('answer')));
      await tester.enterText(find.byKey(const Key('own answer')), 'Both');
      await tester.pump();
      await tester.tap(find.byKey(const Key('answer')));

      expect([for (final m in tui.sent) m['choice']], ['Print', 'Both']);
    });

    testWidgets('shows the answer, wherever it was given', (tester) async {
      await ask(tester);

      tui.send({'type': 'answered', 'question': 7, 'chosen': 'Print'});
      await tester.pump();

      expect(find.text('✓ Print'), findsOneWidget);
      expect(find.byKey(const Key('answer')), findsNothing);
    });
  });

  testWidgets('says when the TUI goes away', (tester) async {
    await connect(tester);
    tui.close();
    await tester.pump();

    expect(find.textContaining('Disconnected'), findsOneWidget);
  });
}
