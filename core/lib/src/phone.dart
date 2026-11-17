import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'diff.dart';
import 'events.dart';
import 'question.dart';
import 'session.dart';

/// A WebSocket server for the phone app, on the same Wi-Fi or over
/// Tailscale. A phone connects to `ws://<address>:<port>/?code=<code>`, and
/// only with the right code. After five wrong codes it stops, so the code
/// can't be guessed.
class PhoneServer {
  PhoneServer._(this._http, this.code, this.onChange);

  /// Listens on [port] on every network interface, or on a free port when
  /// [port] is taken.
  static Future<PhoneServer> start({
    int port = 4545,
    required void Function() onChange,
    Random? random,
  }) async {
    HttpServer http;
    try {
      http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    final code = (random ?? Random.secure())
        .nextInt(1000000)
        .toString()
        .padLeft(6, '0');
    final server = PhoneServer._(http, code, onChange);
    http.listen(server._handle);
    return server;
  }

  final HttpServer _http;

  /// Six digits, shown in the TUI, typed into the app.
  final String code;

  /// Called when a phone connects or leaves, or the server stops.
  final void Function() onChange;

  /// Called with a way to message each phone that connects, so it can be
  /// sent everything so far.
  void Function(void Function(Map<String, dynamic>) send)? onConnect;

  final _phones = <WebSocket>[];
  final _received = StreamController<Map<String, dynamic>>.broadcast();
  var _misses = 0;
  var _closed = false;

  int get port => _http.port;
  bool get connected => _phones.isNotEmpty;
  bool get closed => _closed;

  /// What the phones send: prompts and answers.
  Stream<Map<String, dynamic>> get received => _received.stream;

  Future<void> _handle(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.uri.queryParameters['code'] != code) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      if (++_misses >= 5) await close();
      return;
    }

    final phone = await WebSocketTransformer.upgrade(request);
    _phones.add(phone);
    onConnect?.call((message) => phone.add(jsonEncode(message)));
    onChange();
    phone.listen(
      (data) {
        if (data is! String) return;
        try {
          final message = jsonDecode(data);
          if (message is Map<String, dynamic>) _received.add(message);
        } on FormatException {
          // not JSON: ignore it
        }
      },
      onDone: () {
        _phones.remove(phone);
        onChange();
      },
    );
  }

  /// Sends [message] to every phone.
  void send(Map<String, dynamic> message) {
    final text = jsonEncode(message);
    for (final phone in _phones) {
      phone.add(text);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final phone in [..._phones]) {
      await phone.close();
    }
    _phones.clear();
    await _http.close(force: true);
    onChange();
  }

  /// This machine's IPv4 addresses, the ones a phone could reach.
  static Future<List<String>> addresses() async => [
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      for (final address in interface.addresses)
        if (!address.isLoopback) address.address,
  ];
}

/// Keeps the phones' copy of every session up to date: the session list
/// whenever it changes, each session's new transcript entries, and each
/// question's answer.
class PhoneMirror {
  PhoneMirror(this.server, this.sessions, {this.spent});

  final PhoneServer server;

  /// The app's sessions, in sidebar order.
  final List<Session> Function() sessions;

  /// How a session's spending reads, or null without a price.
  final String? Function(Session session)? spent;

  // session id -> the entries as last sent, to find the first one that changed
  final _sent = <int, List<Entry>>{};
  var _list = '';
  final _waiting = <int, Question>{}; // question id -> unanswered question
  final _questionIds = Expando<int>();
  var _nextQuestion = 0;

  /// Sends what changed since the last call.
  void sync() {
    final list = _sessionList();
    final text = jsonEncode(list);
    if (text != _list) {
      server.send(list);
      _list = text;
    }

    for (final session in sessions()) {
      // entries are only ever added, cleared, or swapped (like /new's note),
      // so everything from the first difference on is what changed
      final sent = _sent[session.id] ?? const <Entry>[];
      final now = session.entries;
      var same = 0;
      while (same < sent.length &&
          same < now.length &&
          identical(sent[same], now[same])) {
        same++;
      }
      if (same < sent.length || same < now.length) {
        server.send(_entries(session, same, reset: same < sent.length));
      }
      _sent[session.id] = [...now];
    }

    for (final MapEntry(key: id, value: question) in [..._waiting.entries]) {
      if (!question.answered) continue;
      server.send({
        'type': 'answered',
        'question': id,
        'chosen': question.chosen,
      });
      _waiting.remove(id);
    }
  }

  /// Everything so far, for a phone that just connected.
  void hello(void Function(Map<String, dynamic>) send) {
    send(_sessionList());
    for (final session in sessions()) {
      send(_entries(session, 0, reset: true));
    }
  }

  /// Handles what a phone sent: an answer here, a prompt through [prompt].
  void receive(
    Map<String, dynamic> message, {
    required void Function(Session session, String text) prompt,
  }) {
    switch (message) {
      case {
        'type': 'prompt',
        'session': final int id,
        'text': final String text,
      }:
        final session = sessions().where((s) => s.id == id).firstOrNull;
        if (session != null && text.trim().isNotEmpty) prompt(session, text);
      case {
        'type': 'answer',
        'question': final int id,
        'choice': final String choice,
      }:
        if (choice.trim().isNotEmpty) _waiting[id]?.reply(choice.trim());
    }
  }

  Map<String, dynamic> _sessionList() => {
    'type': 'sessions',
    'sessions': [
      for (final session in sessions())
        {
          'id': session.id,
          'name': session.name,
          'status': session.status,
          'mood': session.mood.name,
          'busy': session.busy,
          'spent': spent?.call(session),
          if (session.plan case final plan?) ...{
            'orchestrator': true,
            'progress': plan.progress,
            'todos': [
              for (final todo in plan.todos)
                {
                  'id': todo.id,
                  'title': todo.title,
                  'status': todo.label(plan),
                  'worker': ?todo.worker?.name,
                  'workerId': ?todo.worker?.id,
                },
            ],
          },
        },
    ],
  };

  Map<String, dynamic> _entries(
    Session session,
    int from, {
    bool reset = false,
  }) => {
    'type': 'entries',
    'session': session.id,
    'from': from,
    'reset': reset,
    'entries': [for (final entry in session.entries.skip(from)) _entry(entry)],
  };

  int _idOf(Question question) => _questionIds[question] ??= _nextQuestion++;

  Map<String, dynamic> _entry(Entry entry) {
    Map<String, dynamic> note(String text) => {'kind': 'note', 'text': text};
    return switch (entry) {
      PromptEntry(:final text, :final fromPhone, :final from) => {
        'kind': 'prompt',
        'text': text,
        'fromPhone': fromPhone,
        'from': ?from,
      },
      NoteEntry(:final text, :final detail) => {
        ...note(text),
        'detail': ?detail,
      },
      UndoEntry(undo: null) => note('Nothing to undo.'),
      UndoEntry(:final undo?) when !undo.undone => note(
        undo.error == null
            ? '${undo.path} changed after that edit, so /undo left it.'
            : 'Could not undo ${undo.path}: ${undo.error}',
      ),
      UndoEntry(:final undo?) => {
        'kind': 'tool',
        'label': '↺ Undid UpdateFile(path: ${undo.path})',
        'diff': _diff(undo.diff),
      },
      EventEntry(:final event) => switch (event) {
        AssistantText(:final text) => {'kind': 'reply', 'text': text.trim()},
        ToolStarted(:final label, :final diff) => {
          'kind': 'tool',
          'label': label,
          'diff': _diff(diff),
        },
        ToolFinished(:final output, :final failed) => {
          'kind': 'output',
          'text': output.trimRight(),
          'failed': failed,
        },
        CompactionStarted() => note('Summarizing conversation…'),
        Compacted(:final before, :final after) => note(
          'Compacted conversation from $before tokens to $after tokens',
        ),
        Asked(:final question) => _asked(question),
        RetryWait() => note(retryNote(event)),
        AgentError(:final message) => {'kind': 'error', 'text': message},
        UsageReported() => {'kind': 'usage'}, // drawn as nothing
      },
    };
  }

  Map<String, dynamic> _asked(Question question) {
    final id = _idOf(question);
    if (!question.answered) _waiting[id] = question;
    return {
      'kind': 'question',
      'id': id,
      'text': question.text,
      'options': question.options,
      'chosen': question.chosen,
      'from': ?question.asker,
    };
  }

  static List<Map<String, dynamic>> _diff(List<DiffLine> diff) => [
    for (final line in diff)
      {'n': line.number, 'change': line.change.name, 'text': line.text},
  ];
}
