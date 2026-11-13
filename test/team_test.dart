import 'package:coding_agent_in_dart/src/agent.dart';
import 'package:coding_agent_in_dart/src/history.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/plan.dart';
import 'package:coding_agent_in_dart/src/session.dart';
import 'package:coding_agent_in_dart/src/team.dart';
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

Session session(String name) => Session(
  0,
  name,
  Agent(NoProvider(), const []),
  FileHistory(),
  onChange: () {},
);

/// Keeps sessions in a list, and writes down what it was asked to do.
class FakeTeam implements Team {
  FakeTeam(this.sessions);

  @override
  final List<Session> sessions;
  final started = <(Session, String, String)>[];
  final delivered = <(Session, String, Session)>[];

  @override
  Session start(Session by, String name, String task) {
    started.add((by, name, task));
    final made = session(name)..startedBy = by;
    sessions.add(made);
    return made;
  }

  @override
  void deliver(Session to, String text, Session from) =>
      delivered.add((to, text, from));
}

void main() {
  late Session lead, tests, docs;
  late FakeTeam team;

  Tool tool(String name, [Session? self]) =>
      teamTools(team, () => self ?? lead).singleWhere((t) => t.name == name);

  setUp(() {
    lead = session('lead');
    tests = session('tests');
    docs = session('docs');
    team = FakeTeam([lead, tests, docs]);
  });

  group('startSession', () {
    late Plan plan;

    setUp(() {
      plan = Plan(2);
      lead.plan = plan;
      plan.todos.addAll([
        Todo(1, 'write a README'),
        Todo(2, 'link it from the docs', after: [1]),
        Todo(3, 'add a license'),
        Todo(4, 'tag a release'),
      ]);
    });

    test('only an orchestrator has it', () {
      lead.plan = null;
      expect(
        teamTools(team, () => lead).map((t) => t.name),
        isNot(contains('startSession')),
      );
    });

    test('gives a todo to a new worker, started by this session', () async {
      final result = await tool(
        'startSession',
      ).run({'name': 'readme', 'todo': 1, 'task': 'write a README'});

      expect(result, {'session': 'readme', 'todo': 1, 'status': 'started'});
      expect(team.started.single, (lead, 'readme', 'write a README'));
      final todo = plan.byId(1)!;
      expect(todo.status, TodoStatus.working);
      expect(todo.worker?.name, 'readme');
      expect(
        tool('startSession').shows!({'task': 'write a README'}, result),
        'write a README',
      );
    });

    test('refuses a todo that is missing, taken or waiting', () async {
      Future<Object?> give(int todo) async => (await tool(
        'startSession',
      ).run({'name': 'w$todo', 'todo': todo, 'task': 'x'}))['error'];

      expect(await give(9), startsWith('There is no todo 9.'));
      expect(await give(2), startsWith('Todo 2 waits on 1.'));
      await give(1);
      expect(await give(1), 'Todo 1 is working already.');
      expect(team.started, hasLength(1));
    });

    test('runs no more workers at once than the plan allows', () async {
      Future<Map<String, dynamic>> give(int todo) => tool(
        'startSession',
      ).run({'name': 'w$todo', 'todo': todo, 'task': 'x'});

      await give(1);
      await give(3);
      expect(
        (await give(4))['error'],
        startsWith('2 workers are working already, the most at once.'),
      );

      plan.byId(1)!.status = TodoStatus.done;
      expect((await give(4))['status'], 'started');
    });

    test('a worker that is done takes the next todo', () async {
      final readme = session('readme')..startedBy = lead;
      team.sessions.add(readme);
      plan.byId(1)!
        ..worker = readme
        ..status = TodoStatus.done;

      final result = await tool(
        'startSession',
      ).run({'name': 'readme', 'todo': 2, 'task': 'link it'});

      expect(result['session'], 'readme');
      expect(team.started, isEmpty);
      expect(team.delivered.single, (readme, 'link it', lead));
      expect(plan.byId(2)!.worker, readme);
    });

    test('hands nothing out after /stop', () async {
      plan.stopped = true;

      final result = await tool(
        'startSession',
      ).run({'name': 'readme', 'todo': 1, 'task': 'x'});

      expect(result['error'], startsWith('The user stopped this goal'));
    });

    test('stops at $mostSessions sessions', () async {
      team.sessions.addAll([for (var i = 0; i < 9; i++) session('s$i')]);

      final result = await tool(
        'startSession',
      ).run({'name': 'one more', 'todo': 1, 'task': 'x'});

      expect(result['error'], contains('$mostSessions sessions already'));
      expect(team.started, isEmpty);
    });
  });

  test('sending a worker back counts, up to two rounds', () async {
    final plan = Plan(3);
    lead.plan = plan;
    tests.startedBy = lead;
    final todo = Todo(1, 'write the tests')
      ..worker = tests
      ..status = TodoStatus.checking;
    plan.todos.add(todo);

    for (final round in [1, 2]) {
      final result = await tool(
        'sendMessage',
      ).run({'to': 'tests', 'text': 'fix the edge case'});
      expect(result['status'], 'delivered');
      expect((todo.rounds, todo.status), (round, TodoStatus.working));
      todo.status = TodoStatus.checking;
    }

    final result = await tool(
      'sendMessage',
    ).run({'to': 'tests', 'text': 'once more'});
    expect(
      result['error'],
      'You sent tests back twice already. Mark todo 1 done or failed with '
      'updateTodo.',
    );
  });

  group('sendMessage', () {
    test('delivers to a session by name, whatever the case', () async {
      final result = await tool(
        'sendMessage',
      ).run({'to': 'Tests', 'text': 'run them again'});

      expect(result, {'status': 'delivered'});
      expect(team.delivered.single, (tests, 'run them again', lead));
    });

    test("won't send its starter what its last reply sends", () async {
      tests.startedBy = lead;

      final result = await tool(
        'sendMessage',
        tests,
      ).run({'to': 'lead', 'text': 'I wrote the tests'});

      expect(
        result['error'],
        'lead started you, so your last reply goes to it on its own when you '
        'finish. End your turn with your result, or with your question for '
        'it.',
      );
      expect(team.delivered, isEmpty);
    });

    test('says when it waits for a busy session', () async {
      tests.busy = true;

      final result = await tool(
        'sendMessage',
      ).run({'to': 'tests', 'text': 'and the edge cases'});

      expect(result['status'], startsWith('queued: tests is busy'));
      expect(team.delivered, hasLength(1));
    });

    test('names the sessions there are when the name is wrong', () async {
      final result = await tool('sendMessage').run({'to': 'qa', 'text': 'hi'});

      expect(result, {
        'error': 'No session is called qa. The others are: tests, docs.',
      });
    });

    test("can't message itself", () async {
      final result = await tool(
        'sendMessage',
      ).run({'to': 'lead', 'text': 'hi'});

      expect(result, {'error': "That's this session."});
    });
  });

  group('waitFor', () {
    test(
      'waits until each session is idle, then gives its last reply',
      () async {
        tests
          ..busy = true
          ..lastReply = 'still going';
        docs.lastReply = 'Wrote README.md.';
        var done = false;
        final waiting = tool('waitFor')
            .run({
              'sessions': ['tests', 'docs'],
            })
            .then((result) {
              done = true;
              return result;
            });
        await Future<void>.delayed(Duration.zero);

        expect(done, isFalse);
        expect(lead.waitingOn, {tests, docs});
        expect(lead.status, 'idle'); // its mood is the app's to set

        tests
          ..busy = false
          ..lastReply = '6 tests pass.'
          ..settle();
        final result = await waiting;

        expect(result, {
          'replies': {'tests': '6 tests pass.', 'docs': 'Wrote README.md.'},
        });
        expect(lead.waitingOn, isEmpty);
      },
    );

    test('a session with messages left is not done yet', () async {
      tests.inbox.add(Mail('one more thing', lead));
      var done = false;
      final waiting = tool('waitFor')
          .run({
            'sessions': ['tests'],
          })
          .then((_) => done = true);
      await Future<void>.delayed(Duration.zero);

      tests.settle();
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      tests
        ..inbox.clear()
        ..settle();
      await waiting;
      expect(done, isTrue);
    });

    test('drops the reports it already returns', () async {
      final queued = Mail('Wrote the tests.', tests, report: true);
      final question = Mail('Which folder?', docs);
      lead.inbox.addAll([queued, question]);
      tests.lastReply = 'Wrote the tests.';

      await tool('waitFor').run({
        'sessions': ['tests'],
      });

      expect(lead.inbox, [question]);
    });

    test("won't wait on a session that waits on this one", () async {
      tests.waitingOn.add(docs);
      docs.waitingOn.add(lead);

      final result = await tool('waitFor').run({
        'sessions': ['tests'],
      });

      expect(result['error'], startsWith('tests is waiting on this session'));
      expect(lead.waitingOn, isEmpty);
    });

    test("won't wait on itself or a session that isn't there", () async {
      expect(
        await tool('waitFor').run({
          'sessions': ['lead'],
        }),
        {'error': "A session can't wait for itself."},
      );
      expect(
        (await tool('waitFor').run({
          'sessions': ['qa'],
        }))['error'],
        startsWith('No session is called qa.'),
      );
    });

    test('shows the first line of each reply', () {
      final shows = tool('waitFor').shows!;

      expect(
        shows({}, {
          'replies': {'tests': '6 tests pass.\nAll of them.', 'docs': 'Done.'},
        }),
        'tests: 6 tests pass.\ndocs: Done.',
      );
    });
  });

  test('listSessions lists who started whom', () async {
    tests.startedBy = lead;

    final result = await tool('listSessions', tests).run({});

    expect(result, {
      'sessions': [
        {'name': 'lead', 'status': 'idle'},
        {'name': 'tests', 'status': 'idle', 'startedBy': 'lead', 'you': true},
        {'name': 'docs', 'status': 'idle'},
      ],
    });
  });
}
