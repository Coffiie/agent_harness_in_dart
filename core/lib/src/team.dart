import 'plan.dart';
import 'session.dart';
import 'tools.dart';

/// What the team tools need from the app that keeps the sessions.
abstract interface class Team {
  /// Every session, in sidebar order.
  List<Session> get sessions;

  /// Starts a session called [name], made by [by]'s agent, and runs [task]
  /// in it.
  Session start(Session by, String name, String task);

  /// Gives [to] the message [text] from [from]: now when it's free, or
  /// once its turn ends when it's busy.
  void deliver(Session to, String text, Session from);
}

const teamPrompt =
    'You can work with the agents in the other sessions, which share this '
    'project folder. sendMessage writes to a session, waitFor waits until '
    'sessions are done and gives you their last replies, and listSessions '
    'lists them. When another session started you, your last reply goes '
    'back to it on its own when you finish, so end your turn with your '
    "result, or with your question for it; you can't sendMessage it. A "
    'message from another session starts with who sent it; answer it with '
    'sendMessage when it asks you something.';

/// How many sessions there can be, so agents can't start them forever.
const mostSessions = 12;

/// The tools an agent uses to work with other sessions. [self] is the
/// session the agent is in. Only an orchestrator, a session with a plan,
/// gets startSession, and each session it starts works on one of its todos.
List<Tool> teamTools(Team team, Session Function() self) {
  final plan = self().plan;
  Session? find(Object? name) => team.sessions
      .where((s) => s.name.toLowerCase() == '$name'.trim().toLowerCase())
      .firstOrNull;
  String names(Session me) => [
    for (final s in team.sessions)
      if (!identical(s, me)) s.name,
  ].join(', ');
  Map<String, dynamic> missing(Object? name, Session me) => {
    'error':
        'No session is called $name. The others are: '
        '${names(me).isEmpty ? 'none' : names(me)}.',
  };

  return [
    if (plan != null)
      Tool(
        name: 'startSession',
        description:
            'Give a todo to a worker: start an agent in a new session of its '
            'own with a task, or give it to one of your workers that is done, '
            'by its name. The worker has the same tools and project folder, '
            'and works at the same time as you. This returns right away, and '
            "the worker's last reply comes to you as a message when it "
            'finishes.',
        parameters: {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'a short name for the worker, like tests or docs',
            },
            'todo': {'type': 'integer', 'description': 'the todo it works on'},
            'task': {
              'type': 'string',
              'description':
                  "everything the worker needs to know, since it doesn't "
                  'see this chat',
            },
          },
          'required': ['name', 'todo', 'task'],
        },
        label: (args) => 'StartSession(${args['name']}, todo ${args['todo']})',
        run: (args) async {
          final me = self();
          if (plan.stopped) {
            return {
              'error':
                  'The user stopped this goal with /stop. Tell them what was '
                  'done.',
            };
          }
          final todo = plan.byId(args['todo']);
          if (todo == null) {
            return {
              'error':
                  'There is no todo ${args['todo']}. Add it with setTodos '
                  'first.',
            };
          }
          if (todo.status != TodoStatus.pending) {
            return {'error': 'Todo ${todo.id} is ${todo.label(plan)} already.'};
          }
          if (plan.blockers(todo) case final ids when ids.isNotEmpty) {
            return {
              'error':
                  'Todo ${todo.id} waits on ${ids.join(', ')}. Start it once '
                  '${ids.length == 1 ? 'that is' : 'they are'} done.',
            };
          }
          if (plan.working.length >= plan.limit) {
            return {
              'error':
                  '${plan.limit} workers are working already, the most at '
                  'once. Start this one when a worker finishes.',
            };
          }

          // one of its workers that is done can take the next todo
          final name = '${args['name']}'.trim();
          final known = find(name);
          final Session worker;
          if (known != null &&
              identical(known.startedBy, me) &&
              known.idle &&
              plan.of(known)?.status != TodoStatus.checking) {
            worker = known;
            team.deliver(worker, '${args['task']}', me);
          } else {
            if (team.sessions.length >= mostSessions) {
              return {
                'error':
                    'There are $mostSessions sessions already, the most there '
                    'can be. Give the todo to one of your workers that is '
                    'done.',
              };
            }
            worker = team.start(me, name, '${args['task']}');
          }
          todo
            ..worker = worker
            ..status = TodoStatus.working
            ..started = plan.now();
          return {'session': worker.name, 'todo': todo.id, 'status': 'started'};
        },
        shows: (args, _) => '${args['task']}',
      ),
    Tool(
      name: 'sendMessage',
      description:
          'Send a message to another session. It runs there like a prompt, '
          'right away, or when that session finishes what it is doing.',
      parameters: {
        'type': 'object',
        'properties': {
          'to': {'type': 'string', 'description': 'the session name'},
          'text': {'type': 'string', 'description': 'the message'},
        },
        'required': ['to', 'text'],
      },
      label: (args) => 'SendMessage(to: ${args['to']})',
      run: (args) async {
        final me = self();
        final to = find(args['to']);
        if (to == null) return missing(args['to'], me);
        if (identical(to, me)) return {'error': "That's this session."};
        // its last reply goes to its starter on its own; a message on top
        // would make the starter take another turn for the same news
        if (identical(me.startedBy, to)) {
          return {
            'error':
                '${to.name} started you, so your last reply goes to it on '
                'its own when you finish. End your turn with your result, or '
                'with your question for it.',
          };
        }
        // sending a worker back to fix its todo
        if (plan?.of(to) case final todo?
            when todo.status == TodoStatus.checking) {
          if (todo.rounds >= 2) {
            return {
              'error':
                  'You sent ${to.name} back twice already. Mark todo '
                  '${todo.id} done or failed with updateTodo.',
            };
          }
          todo
            ..rounds += 1
            ..status = TodoStatus.working;
        }
        final busy = to.busy;
        team.deliver(to, '${args['text']}', me);
        return {
          'status': busy
              ? 'queued: ${to.name} is busy, and reads it when its turn ends'
              : 'delivered',
        };
      },
      shows: (args, _) => '${args['text']}',
    ),
    Tool(
      name: 'waitFor',
      description:
          'Wait until sessions are done with their work and their messages, '
          'then get the last reply of each.',
      parameters: {
        'type': 'object',
        'properties': {
          'sessions': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'the session names',
          },
        },
        'required': ['sessions'],
      },
      label: (args) =>
          'WaitFor(${(args['sessions'] as List? ?? []).join(', ')})',
      run: (args) async {
        final me = self();
        final targets = <Session>[];
        for (final name in args['sessions'] as List? ?? const []) {
          final target = find(name);
          if (target == null) return missing(name, me);
          if (identical(target, me)) {
            return {'error': "A session can't wait for itself."};
          }
          if (target.waitsOn(me)) {
            return {
              'error':
                  '${target.name} is waiting on this session, so waiting on '
                  'it would never end. Send it a message instead.',
            };
          }
          targets.add(target);
        }
        me.waitingOn.addAll(targets);
        try {
          await Future.wait([for (final t in targets) t.whenIdle()]);
        } finally {
          me.waitingOn.removeAll(targets);
        }
        // their replies are in the result, so reports from them that came
        // in before this call would only say it again
        me.inbox.removeWhere((m) => m.report && targets.contains(m.from));
        return {
          'replies': {
            for (final t in targets) t.name: t.lastReply ?? '(no reply)',
          },
        };
      },
      shows: (args, result) => [
        for (final MapEntry(:key, :value)
            in (result['replies'] as Map? ?? {}).entries)
          '$key: ${'$value'.trim().split('\n').first}',
      ].join('\n'),
    ),
    Tool(
      name: 'listSessions',
      description:
          'List the sessions: their names, what they are doing, and which '
          'session started them.',
      parameters: {'type': 'object', 'properties': {}},
      label: (_) => 'ListSessions()',
      run: (_) async => {
        'sessions': [
          for (final s in team.sessions)
            {
              'name': s.name,
              'status': s.status,
              if (s.startedBy case final by?) 'startedBy': by.name,
              if (identical(s, self())) 'you': true,
            },
        ],
      },
    ),
  ];
}
