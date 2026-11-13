import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:coding_agent_in_dart/src/agent.dart';
import 'package:coding_agent_in_dart/src/events.dart';
import 'package:coding_agent_in_dart/src/history.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/phone.dart';
import 'package:coding_agent_in_dart/src/plan.dart';
import 'package:coding_agent_in_dart/src/question.dart';
import 'package:coding_agent_in_dart/src/session.dart';
import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:test/test.dart';

class NoProvider implements ModelProvider {
  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) => throw UnimplementedError();

  @override
  Future<int> countTokens(List<Message> messages) async => 0;
}

/// A phone: the messages the server sent it, and a way to reply.
class Phone {
  Phone(this.socket) {
    socket.listen((data) => messages.add(jsonDecode(data as String)));
  }

  final WebSocket socket;
  final messages = <Map<String, dynamic>>[];

  static Future<Phone> connect(PhoneServer server, [String? code]) async =>
      Phone(
        await WebSocket.connect(
          'ws://127.0.0.1:${server.port}/?code=${code ?? server.code}',
        ),
      );

  void send(Map<String, dynamic> message) => socket.add(jsonEncode(message));

  Iterable<Map<String, dynamic>> ofType(String type) =>
      messages.where((m) => m['type'] == type);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late PhoneServer server;
  late List<Session> sessions;
  late PhoneMirror mirror;

  Session session(int id, String name) => Session(
    id,
    name,
    Agent(NoProvider(), []),
    FileHistory(),
    onChange: () {},
  );

  setUp(() async {
    server = await PhoneServer.start(port: 0, onChange: () {});
    sessions = [session(1, 'tower hanoi')];
    mirror = PhoneMirror(server, () => sessions);
    server.onConnect = mirror.hello;
  });

  tearDown(() => server.close());

  group('PhoneServer', () {
    test('makes a six digit code', () async {
      final seeded = await PhoneServer.start(
        port: 0,
        onChange: () {},
        random: Random(1),
      );
      addTearDown(seeded.close);

      expect(seeded.code, matches(RegExp(r'^\d{6}$')));
    });

    test('turns away a wrong code', () async {
      await expectLater(
        Phone.connect(server, 'nope'),
        throwsA(isA<WebSocketException>()),
      );
      expect(server.connected, isFalse);
    });

    test('stops after five wrong codes', () async {
      for (var i = 0; i < 5; i++) {
        await expectLater(Phone.connect(server, 'nope'), throwsA(anything));
      }
      await settle();

      expect(server.closed, isTrue);
    });

    test('sends a phone that connects everything so far', () async {
      sessions.first.entries.add(const PromptEntry('hello'));

      final phone = await Phone.connect(server);
      await settle();

      expect(server.connected, isTrue);
      expect(phone.ofType('sessions').single['sessions'], [
        {
          'id': 1,
          'name': 'tower hanoi',
          'status': 'idle',
          'mood': 'waiting',
          'busy': false,
          'spent': null,
        },
      ]);
      final entries = phone.ofType('entries').single;
      expect(entries['reset'], isTrue);
      expect(entries['entries'], [
        {'kind': 'prompt', 'text': 'hello', 'fromPhone': false},
      ]);
    });
  });

  group('PhoneMirror', () {
    test('sends only the entries that are new', () async {
      final phone = await Phone.connect(server);
      await settle();
      mirror.sync(); // nothing new since hello
      sessions.first.entries.add(const EventEntry(AssistantText('Paris')));
      mirror.sync();
      mirror.sync();
      await settle();

      final sent = phone.ofType('entries').toList();
      expect(sent, hasLength(2)); // hello, then the reply once
      expect(sent.last['from'], 0);
      expect(sent.last['entries'], [
        {'kind': 'reply', 'text': 'Paris'},
      ]);
    });

    test('starts over when the transcript is cleared', () async {
      sessions.first.entries.add(const PromptEntry('hello'));
      mirror.sync();
      final phone = await Phone.connect(server);
      await settle();

      sessions.first.entries.clear();
      mirror.sync();
      await settle();

      expect(phone.ofType('entries').last, {
        'type': 'entries',
        'session': 1,
        'from': 0,
        'reset': true,
        'entries': [],
      });
    });

    test('resends an entry swapped in place, like /new\'s note', () async {
      final asking = NoteEntry('Asking Gemini whether this needs tower hanoi…');
      sessions.first.entries.add(asking);
      mirror.sync();
      final phone = await Phone.connect(server);
      await settle();

      sessions.first.entries
        ..removeLast()
        ..add(NoteEntry("Gemini says this doesn't need tower hanoi."));
      mirror.sync();
      await settle();

      final last = phone.ofType('entries').last;
      expect(last['from'], 0);
      expect(last['reset'], isTrue);
      expect(last['entries'], [
        {'kind': 'note', 'text': "Gemini says this doesn't need tower hanoi."},
      ]);
    });

    test('sends the session list when it changes', () async {
      final phone = await Phone.connect(server);
      await settle();

      sessions.add(session(2, 'readme'));
      mirror.sync();
      await settle();

      final names = [
        for (final s in phone.ofType('sessions').last['sessions']) s['name'],
      ];
      expect(names, ['tower hanoi', 'readme']);
    });

    test("sends an orchestrator's todos, and who asked a question", () async {
      final readme = session(2, 'readme');
      final plan = Plan(3);
      plan.todos.addAll([
        Todo(1, 'write a README')
          ..worker = readme
          ..status = TodoStatus.working,
        Todo(2, 'add an example', after: [1]),
      ]);
      sessions.first.plan = plan;
      sessions.add(readme);
      final question = Question('Which license?', ['MIT'])..asker = 'readme';
      sessions.first.entries.add(EventEntry(Asked(question)));

      final phone = await Phone.connect(server);
      await settle();

      final lead = phone.ofType('sessions').last['sessions'].first;
      expect(lead['orchestrator'], isTrue);
      expect(lead['progress'], '0/2');
      expect(lead['todos'], [
        {
          'id': 1,
          'title': 'write a README',
          'status': 'working',
          'worker': 'readme',
          'workerId': 2,
        },
        {'id': 2, 'title': 'add an example', 'status': 'waits on 1'},
      ]);
      final asked = phone.ofType('entries').first['entries'].single;
      expect(asked['from'], 'readme');
    });

    test(
      'a question can be answered from the phone, and the answer is sent',
      () async {
        final question = Question('Print or return?', ['Return', 'Print']);
        sessions.first.entries.add(EventEntry(Asked(question)));
        final phone = await Phone.connect(server);
        await settle();

        final asked = phone.ofType('entries').single['entries'].single;
        expect(asked['kind'], 'question');
        expect(asked['options'], ['Return', 'Print']);
        expect(asked['chosen'], isNull);

        mirror.receive({
          'type': 'answer',
          'question': asked['id'],
          'choice': 'Print',
        }, prompt: (_, _) {});
        expect(question.chosen, 'Print');

        mirror.sync();
        await settle();
        expect(phone.ofType('answered').single, {
          'type': 'answered',
          'question': asked['id'],
          'chosen': 'Print',
        });
      },
    );

    test('hands a prompt to its session', () async {
      final prompts = <(int, String)>[];

      mirror.receive({
        'type': 'prompt',
        'session': 1,
        'text': 'add a test',
      }, prompt: (s, text) => prompts.add((s.id, text)));
      mirror.receive({
        'type': 'prompt',
        'session': 9,
        'text': 'no such session',
      }, prompt: (s, text) => prompts.add((s.id, text)));

      expect(prompts, [(1, 'add a test')]);
    });

    test('sends a file edit with its diff', () async {
      final phone = await Phone.connect(server);
      await settle();
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final tools = fileTools();
      final update = tools.firstWhere((t) => t.name == 'updateFile');
      final args = {'path': '${dir.path}/a.txt', 'content': 'one\n'};

      sessions.first.entries.add(
        EventEntry(ToolStarted('UpdateFile', diff: update.diff!(args))),
      );
      mirror.sync();
      await settle();

      expect(phone.ofType('entries').last['entries'].single, {
        'kind': 'tool',
        'label': 'UpdateFile',
        'diff': [
          {'n': 1, 'change': 'added', 'text': 'one'},
        ],
      });
    });

    test('sends which session a prompt came from', () async {
      final phone = await Phone.connect(server);
      await settle();

      sessions.first.entries.add(const PromptEntry('run it', from: 'lead'));
      mirror.sync();
      await settle();

      expect(phone.ofType('entries').last['entries'].last, {
        'kind': 'prompt',
        'text': 'run it',
        'fromPhone': false,
        'from': 'lead',
      });
    });

    test("sends a tool's output, and whether it failed", () async {
      final phone = await Phone.connect(server);
      await settle();

      sessions.first.entries
        ..add(EventEntry(const ToolStarted('RunCommand(dart test)')))
        ..add(
          EventEntry(const ToolFinished('Some tests failed.\n', failed: true)),
        );
      mirror.sync();
      await settle();

      expect(phone.ofType('entries').last['entries'].last, {
        'kind': 'output',
        'text': 'Some tests failed.',
        'failed': true,
      });
    });
  });
}
