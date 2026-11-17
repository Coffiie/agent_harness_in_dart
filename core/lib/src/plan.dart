import 'session.dart';
import 'tools.dart';

/// Where a todo is. A worker that asks the user something shows as "asks
/// you" on top of this; see [Todo.label].
enum TodoStatus {
  /// Not handed out yet.
  pending,

  /// A worker has it.
  working,

  /// Its worker finished, and the orchestrator hasn't ticked it yet.
  checking,
  done,
  failed,
}

/// One piece of an orchestrator's plan.
class Todo {
  Todo(this.id, this.title, {this.after = const []});

  /// Counts up from 1 in its plan.
  final int id;
  final String title;

  /// The todos that have to be done before this one starts.
  final List<int> after;

  var status = TodoStatus.pending;

  /// The session doing it, once it's handed out.
  Session? worker;
  DateTime? started;
  DateTime? finished;

  /// How many times the orchestrator sent the work back.
  var rounds = 0;

  /// Why it was marked done or failed, when the orchestrator said.
  String? note;

  bool get open => status != TodoStatus.done && status != TodoStatus.failed;

  /// What the todo panel says about it, without the time.
  String label(Plan plan) => switch (status) {
    TodoStatus.working when worker?.question != null => 'asks you',
    TodoStatus.pending when plan.blockers(this).isNotEmpty =>
      'waits on ${plan.blockers(this).join(', ')}',
    TodoStatus.pending => 'ready',
    TodoStatus.working => 'working',
    TodoStatus.checking => 'checking',
    TodoStatus.done => 'done',
    TodoStatus.failed => 'failed',
  };
}

/// An orchestrator's todo list, and how many workers it runs at once.
/// Holding a plan is what makes a session an orchestrator.
class Plan {
  Plan(this.limit, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      started = (clock ?? DateTime.now)();

  /// How many workers can work at the same time.
  final int limit;
  final DateTime started;
  final DateTime Function() _clock;

  final todos = <Todo>[];

  /// Set by /stop: nothing new gets handed out.
  var stopped = false;

  DateTime now() => _clock();

  Todo? byId(Object? id) {
    final n = id is num ? id.toInt() : int.tryParse('$id');
    return todos.where((t) => t.id == n).firstOrNull;
  }

  /// The todo [worker] has now, or had last.
  Todo? of(Session worker) =>
      todos.where((t) => identical(t.worker, worker)).lastOrNull;

  int get done => todos.where((t) => t.status == TodoStatus.done).length;

  /// The todos a worker is on right now.
  Iterable<Todo> get working =>
      todos.where((t) => t.status == TodoStatus.working);

  /// Whether any worker is still at it.
  bool get running => working.isNotEmpty;

  /// The ids of the todos [todo] still waits for.
  List<int> blockers(Todo todo) => [
    for (final id in todo.after)
      if (byId(id)?.status != TodoStatus.done) id,
  ];

  /// "2/4", for the sidebar.
  String get progress => '$done/${todos.length}';

  /// How long the plan has run: until now, or until its last todo closed.
  Duration get elapsed {
    final closed = todos.isNotEmpty && !todos.any((t) => t.open);
    final end = closed
        ? todos
              .map((t) => t.finished ?? started)
              .reduce((a, b) => a.isAfter(b) ? a : b)
        : now();
    return end.difference(started);
  }
}

/// What an orchestrator can run: checks that read the project and never
/// change it, each with any arguments after it.
const checks = [
  'dart test',
  'dart analyze',
  'dart format --output=none',
  'flutter test',
  'flutter analyze',
  'git diff',
  'git status',
  'git log',
  'git show',
];

/// Whether [command] is one of the [checks], on its own: no ; && | > or
/// anything else that could start a second command or write a file.
bool isCheck(String command) {
  final words = command.trim().split(RegExp(r'\s+'));
  final line = words.join(' ');
  if (RegExp(r'[;&|<>`$\\(){}\n]').hasMatch(command)) return false;
  // options that write a file, even on a check
  final rest = line.startsWith('dart format') ? words.skip(3) : words;
  if (rest.any(
    (w) =>
        w.startsWith('--output') ||
        w == '-o' ||
        w.startsWith('--file-reporter') ||
        w == '--coverage',
  )) {
    return false;
  }
  return checks.any((c) => line == c || line.startsWith('$c '));
}

/// [runCommand], cut down to the [checks], for an orchestrator: every
/// change sits in a worker's session, where /undo can take it back.
Tool checkTool(Tool runCommand) => Tool(
  name: 'runCheck',
  description:
      'Run a check in the project folder, and get its output and exit code. '
      'Only these run, each with any arguments after it: '
      '${checks.join(', ')}.',
  parameters: runCommand.parameters,
  label: (args) => 'RunCheck(${args['command']})',
  run: (args) async {
    final command = '${args['command'] ?? ''}'.trim();
    if (!isCheck(command)) {
      return {
        'error':
            "runCheck only runs checks (${checks.join(', ')}), one at a "
            'time. Changing files is a worker\'s job: give it to one with '
            'startSession.',
      };
    }
    return runCommand.run({'command': command});
  },
);

const _todoSchema = {
  'type': 'object',
  'properties': {
    'title': {'type': 'string', 'description': 'what to do, in a line'},
    'after': {
      'type': 'array',
      'items': {'type': 'integer'},
      'description': 'ids of the todos that must be done first',
    },
  },
  'required': ['title'],
};

/// The tools an orchestrator keeps its todo list with.
List<Tool> planTools(Plan plan) => [
  Tool(
    name: 'setTodos',
    description:
        'Add todos to your plan, in order. Each gets the next id, counting '
        'from 1 across the whole plan, so a todo added later can come after '
        'one added now. Give each todo to a worker with startSession once '
        'the todos in its after list are done.',
    parameters: {
      'type': 'object',
      'properties': {
        'todos': {'type': 'array', 'items': _todoSchema},
      },
      'required': ['todos'],
    },
    label: (args) => 'SetTodos(${(args['todos'] as List? ?? []).length})',
    run: (args) async {
      final added = <Todo>[];
      for (final item in args['todos'] as List? ?? const []) {
        if (item is! Map || '${item['title'] ?? ''}'.trim().isEmpty) continue;
        final todo = Todo(
          plan.todos.length + 1,
          '${item['title']}'.trim(),
          after: [
            for (final id in item['after'] as List? ?? const [])
              if (id is num && id.toInt() <= plan.todos.length) id.toInt(),
          ],
        );
        plan.todos.add(todo);
        added.add(todo);
      }
      if (added.isEmpty) return {'error': 'setTodos needs todos with titles'};
      return {
        'added': [
          for (final t in added)
            {
              'id': t.id,
              'title': t.title,
              if (t.after.isNotEmpty) 'after': t.after,
            },
        ],
      };
    },
    shows: (args, result) => [
      for (final t in result['added'] as List? ?? const [])
        '${t['id']} ${t['title']}'
            '${t['after'] == null ? '' : '  after ${(t['after'] as List).join(', ')}'}',
    ].join('\n'),
  ),
  Tool(
    name: 'updateTodo',
    description:
        'Mark a todo done once you checked its worker\'s work, or failed when '
        'it can\'t be done or was sent back twice already.',
    parameters: {
      'type': 'object',
      'properties': {
        'todo': {'type': 'integer', 'description': 'the todo id'},
        'status': {
          'type': 'string',
          'enum': ['done', 'failed'],
        },
        'note': {'type': 'string', 'description': 'why, in a line'},
      },
      'required': ['todo', 'status'],
    },
    label: (args) => 'UpdateTodo(${args['todo']}: ${args['status']})',
    run: (args) async {
      final todo = plan.byId(args['todo']);
      if (todo == null) return {'error': 'There is no todo ${args['todo']}.'};
      final status = switch (args['status']) {
        'done' => TodoStatus.done,
        'failed' => TodoStatus.failed,
        _ => null,
      };
      if (status == null) return {'error': 'status is done or failed'};
      todo
        ..status = status
        ..finished = plan.now()
        ..note = args['note'] == null ? null : '${args['note']}';
      final open = plan.todos.where((t) => t.open).length;
      return {
        'todo': todo.id,
        'status': status.name,
        'open': open,
        if (open == 0) 'next': 'Every todo is closed: report to the user.',
      };
    },
    shows: (args, result) => args['note'] == null ? null : '${args['note']}',
  ),
];

/// What the orchestrator is told, on top of [teamPrompt]'s messaging.
String orchestratorPrompt({required int limit, required bool canRun}) =>
    "You are an orchestrator in a terminal UI. You don't change files "
    'yourself: you plan the work, hand it to worker agents, and check what '
    'they did. Every change to a file, even a new folder, is a worker\'s '
    'job. When the user gives you a goal, read enough of the project to '
    'plan it, then call setTodos with small todos that a worker can each '
    'finish on its own, with after for a todo that needs others done first. '
    'Give each todo that is ready to a worker with startSession, up to '
    '$limit at once, and give the worker everything it needs in the task, '
    "since it doesn't see this chat. When a worker finishes, its last reply "
    'comes to you as a message. Then check its work: read the files it '
    'changed${canRun ? ' and run the tests with runCheck' : ''}. If it is '
    'right, call updateTodo with done. If not, send the worker back with '
    'sendMessage and say what to fix; after two rounds, mark the todo '
    'failed. Hand out the next todos as others finish; a worker that is done '
    'can take another todo when you start a session with its name. When '
    'every todo is done or failed, give the user a short report: what each '
    'worker did${canRun ? ', whether the tests pass' : ''}, and anything '
    'that failed. The user can give you another goal while you work: add its '
    'todos with setTodos. When a worker asks the user something, the '
    "question shows here too, so you don't answer it. When you need the "
    'user to decide something yourself, call askUser with the choices, the '
    'one you recommend first.';
