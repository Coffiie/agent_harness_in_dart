import 'package:coding_agent_core/src/agent.dart';
import 'package:coding_agent_core/src/history.dart';
import 'package:coding_agent_core/src/messages.dart';
import 'package:coding_agent_core/src/model_provider.dart';
import 'package:coding_agent_core/src/plan.dart';
import 'package:coding_agent_core/src/question.dart';
import 'package:coding_agent_core/src/session.dart';
import 'package:coding_agent_core/src/tools.dart';
import 'package:test/test.dart';

class NoProvider implements ModelProvider {
  @override
  String get name => 'Gemini';

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) => throw UnimplementedError();

  @override
  Future<int> countTokens(List<Message> messages) async => 0;
}

Session worker(String name) => Session(
  0,
  name,
  Agent(NoProvider(), const []),
  FileHistory(),
  onChange: () {},
);

void main() {
  late Plan plan;
  Tool tool(String name) => planTools(plan).singleWhere((t) => t.name == name);

  setUp(() => plan = Plan(3));

  group('setTodos', () {
    test('numbers todos across the plan, with what they wait for', () async {
      final first = await tool('setTodos').run({
        'todos': [
          {'title': 'write hanoi'},
          {
            'title': 'test it',
            'after': [1],
          },
        ],
      });
      final second = await tool('setTodos').run({
        'todos': [
          {
            'title': 'document it',
            'after': [2, 7],
          },
        ],
      });

      expect(first['added'], [
        {'id': 1, 'title': 'write hanoi'},
        {
          'id': 2,
          'title': 'test it',
          'after': [1],
        },
      ]);
      // a todo can only wait on one that's already there
      expect(plan.byId(3)!.after, [2]);
      expect(second['added'], hasLength(1));
      expect(
        tool('setTodos').shows!({}, first),
        '1 write hanoi\n2 test it  after 1',
      );
    });

    test('needs a title', () async {
      final result = await tool('setTodos').run({
        'todos': [
          {'title': ' '},
        ],
      });
      expect(result['error'], 'setTodos needs todos with titles');
      expect(plan.todos, isEmpty);
    });
  });

  test('updateTodo closes a todo, and says when every one is', () async {
    plan.todos.addAll([Todo(1, 'a'), Todo(2, 'b')]);

    final done = await tool(
      'updateTodo',
    ).run({'todo': 1, 'status': 'done', 'note': 'tests pass'});
    final failed = await tool(
      'updateTodo',
    ).run({'todo': 2, 'status': 'failed'});

    expect(done, {'todo': 1, 'status': 'done', 'open': 1});
    expect(failed['next'], 'Every todo is closed: report to the user.');
    expect(plan.byId(1)!.note, 'tests pass');
    expect(plan.done, 1);
    expect(plan.progress, '1/2');
    expect(
      (await tool('updateTodo').run({'todo': 5, 'status': 'done'}))['error'],
      'There is no todo 5.',
    );
  });

  test('a todo says where it is', () {
    final readme = worker('readme');
    final a = Todo(1, 'a');
    final b = Todo(2, 'b', after: [1]);
    plan.todos.addAll([a, b]);

    expect(a.label(plan), 'ready');
    expect(b.label(plan), 'waits on 1');

    a
      ..worker = readme
      ..status = TodoStatus.working;
    expect(a.label(plan), 'working');
    expect(plan.running, isTrue);

    readme.question = Question('Which license?', ['MIT']);
    expect(a.label(plan), 'asks you');

    a.status = TodoStatus.done;
    expect(b.label(plan), 'ready');
    expect(plan.of(readme), a);
  });

  test("the plan's clock stops when its last todo closes", () {
    var now = DateTime(2026, 11, 13, 12);
    plan = Plan(3, clock: () => now);
    final a = Todo(1, 'a');
    final b = Todo(2, 'b');
    plan.todos.addAll([a, b]);

    now = now.add(const Duration(seconds: 40));
    a
      ..status = TodoStatus.done
      ..finished = now;
    now = now.add(const Duration(seconds: 35));
    expect(plan.elapsed, const Duration(seconds: 75));

    b
      ..status = TodoStatus.failed
      ..finished = now;
    now = now.add(const Duration(minutes: 9));
    expect(plan.elapsed, const Duration(seconds: 75));
  });

  group('runCheck', () {
    final ran = <String>[];
    final runCommand = Tool(
      name: 'runCommand',
      description: 'run',
      parameters: {'type': 'object'},
      label: (_) => '',
      run: (args) async {
        ran.add(args['command'] as String);
        return {'exitCode': 0, 'output': 'ok'};
      },
    );
    setUp(ran.clear);

    test('runs checks, with their arguments', () async {
      final check = checkTool(runCommand);
      for (final command in [
        'dart test',
        'dart test test/stack_test.dart --name push',
        'dart analyze lib',
        'dart format --output=none --set-exit-if-changed .',
        'git diff lib/stack.dart',
        'git status',
      ]) {
        expect(await check.run({'command': command}), {
          'exitCode': 0,
          'output': 'ok',
        });
      }
      expect(ran, hasLength(6));
      expect(check.label({'command': 'dart test'}), 'RunCheck(dart test)');
    });

    test('refuses anything that could change a file', () async {
      final check = checkTool(runCommand);
      for (final command in [
        'mkdir -p lib test',
        'dart format .',
        'dart test; rm -rf lib',
        'dart test && touch x',
        'git diff > patch.txt',
        'git diff --output=patch.txt',
        'dart test --file-reporter=json:out.json',
        'flutter test --coverage',
        r'echo $(rm x)',
        'git checkout .',
      ]) {
        final result = await check.run({'command': command});
        expect(
          result['error'],
          startsWith('runCheck only runs checks'),
          reason: command,
        );
      }
      expect(ran, isEmpty);
    });
  });

  test('the orchestrator is told its limit, and to test when it can', () {
    expect(orchestratorPrompt(limit: 3, canRun: true), contains('up to 3'));
    expect(
      orchestratorPrompt(limit: 3, canRun: true),
      contains('run the tests with runCheck'),
    );
    expect(
      orchestratorPrompt(limit: 3, canRun: true),
      contains("Every change to a file, even a new folder, is a worker's job."),
    );
    expect(
      orchestratorPrompt(limit: 3, canRun: false),
      isNot(contains('runCheck')),
    );
  });
}
