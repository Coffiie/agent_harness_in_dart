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
    'You can work with other agents, each in a session of its own with the '
    'same tools and the same project folder. startSession starts one on a '
    'task, sendMessage writes to a session, waitFor waits until sessions are '
    'done and gives you their last replies, and listSessions lists them. '
    'When a task splits into parts that can be done at the same time, start '
    'a session for each part, wait for them, then check their work. A new '
    "session doesn't see your chat, so give it everything it needs in the "
    'task. When a session you started finishes, its last reply comes to '
    "you as a message, unless you're waiting on it with waitFor. When "
    'another session started you, your last reply goes back to it on its '
    "own when you finish, so don't send it your result with sendMessage; "
    'use sendMessage to ask it something. A message from another session '
    'starts with who sent it; answer it with sendMessage when it asks you '
    'something.';

/// How many sessions there can be, so agents can't start them forever.
const mostSessions = 8;

/// The tools an agent uses to work with other sessions. [self] is the
/// session the agent is in.
List<Tool> teamTools(Team team, Session Function() self) {
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
    Tool(
      name: 'startSession',
      description:
          'Start another agent in a new session of its own, and give it a '
          'task. It works at the same time as you, with the same tools and '
          'project folder. It returns right away; call waitFor to get the '
          'result.',
      parameters: {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'a short name for the session, like tests or docs',
          },
          'task': {
            'type': 'string',
            'description':
                "everything the new agent needs to know, since it doesn't "
                'see this chat',
          },
        },
        'required': ['name', 'task'],
      },
      label: (args) => 'StartSession(${args['name']})',
      run: (args) async {
        if (team.sessions.length >= mostSessions) {
          return {
            'error':
                'There are $mostSessions sessions already, the most there '
                'can be. Use the ones there are.',
          };
        }
        final session = team.start(
          self(),
          '${args['name']}',
          '${args['task']}',
        );
        return {'session': session.name, 'status': 'started'};
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
