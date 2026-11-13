import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:nocterm/nocterm.dart';

import 'agent.dart';
import 'design_system/colors.dart';
import 'design_system/theme.dart';
import 'diff.dart';
import 'events.dart';
import 'history.dart';
import 'messages.dart';
import 'model_provider.dart';
import 'phone.dart';
import 'question.dart';
import 'sandbox.dart';
import 'session.dart';
import 'settings.dart';
import 'term.dart';
import 'tools.dart';
import 'usage.dart';

export 'session.dart' show sessionName;

const _maxDiffLines = 14;

// The sessions sidebar, and the rail it folds into. Below [_railBelow]
// columns the rail shows instead, so the chat keeps its width.
const _sidebarWidth = 34;
const _railWidth = 8;
const _railBelow = 110;

/// The commands that work while the session is busy.
const _anytime = {'/new', '/settings', '/exit', '/phone'};

/// The commands the phone can't send: they belong to the terminal.
const _terminalOnly = {'/exit', '/settings', '/phone'};

// How many of a tool's last output lines show under it.
const _outputRows = 8;

/// 3318 -> "3,318".
String grouped(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// Dollars to four places, so a fraction of a cent still shows: "$0.0006".
String dollars(double amount) => '\$${amount.toStringAsFixed(4)}';

// The TUI draws the harness's own diff under every file edit (see _diff), so
// the model is told not to write one.
const systemPrompt =
    'You are a coding agent running in a terminal UI. You can list, read and '
    'update files with your tools. Every time you call updateFile, the UI '
    'shows the user an exact diff of the change, worked out from the file on '
    'disk, right under the tool call. Never write a diff, a patch or lines '
    'marked with + and - yourself, in any reply, even when the user asks to '
    'see the diff or the changes: that diff is already on screen, so point '
    'them to it. Do not paste the code you just wrote unless the user asks '
    'for the code. After an edit, say in a sentence or two what you changed '
    'and why. When you need the user to decide something, call askUser with '
    'the choices, the one you recommend first, instead of asking in a '
    'reply.';

const sandboxPrompt =
    'Your tools run in a sandbox: a container with no network, where the only '
    'folders from this computer are the project folder and, read-only, '
    "Dart's package cache. runCommand runs shell commands there, like dart "
    "test. When something can't be done inside it, like reaching the "
    "internet or a file outside the project, say so and don't look for a way "
    'around it.';

/// What the model is told after /undo, so it doesn't go on as if its edit
/// were still there.
String undoNote(Undo undo) => undo.deleted
    ? '[The user ran /undo. Your edit created ${undo.path}, so that file '
          'was deleted.]'
    : '[The user ran /undo. Your last edit to ${undo.path} was undone, and '
          'the file is back to what it was before that edit. Read it again '
          'before you change it.]';

/// A place on screen, in cells.
typedef _Box = ({int x, int y, int w, int h});

/// Where [n] panes go in a [w] by [h] area: side by side for two, two on
/// top and one below for three, two by two for four.
List<_Box> _gridBoxes(int n, int w, int h) {
  if (n <= 1) return [(x: 0, y: 0, w: w, h: h)];
  final w1 = w ~/ 2, w2 = w - w1;
  if (n == 2) return [(x: 0, y: 0, w: w1, h: h), (x: w1, y: 0, w: w2, h: h)];
  final h1 = h ~/ 2, h2 = h - h1;
  return [
    (x: 0, y: 0, w: w1, h: h1),
    (x: w1, y: 0, w: w2, h: h1),
    if (n == 3)
      (x: 0, y: h1, w: w, h: h2)
    else ...[
      (x: 0, y: h1, w: w1, h: h2),
      (x: w1, y: h1, w: w2, h: h2),
    ],
  ];
}

/// What the mouse is over.
sealed class _Hit {
  const _Hit();
}

class _Fold extends _Hit {
  const _Fold();
}

class _Row extends _Hit {
  const _Row(this.session);

  final Session session;
}

/// A pane, or its title bar when [title], where a drag starts.
class _Pane extends _Hit {
  const _Pane(this.session, {this.title = false});

  final Session session;
  final bool title;
}

/// A session being dragged: from the sidebar into the window to split it,
/// or by a pane's title back to the sidebar.
class _Drag {
  _Drag(
    this.session, {
    required this.fromPane,
    required this.x,
    required this.y,
  });

  final Session session;
  final bool fromPane;
  int x, y;
}

class HarnessApp extends StatefulComponent {
  const HarnessApp({
    super.key,
    required this.provider,
    required this.model,
    this.settingsFile,
    this.onQuestion,
    this.phonePort = 4545,
    this.sandbox,
  });

  /// Where the agents' tools run. Without one they run on this computer,
  /// with file tools only.
  final Sandbox? sandbox;

  final ModelProvider provider;
  final String model;

  /// Where /settings saves its choices. With none, they last until the app
  /// quits.
  final File? settingsFile;

  /// Called with each question the model asks, so something else can
  /// answer it too. The first answer wins.
  final void Function(Question question)? onQuestion;

  /// Where /phone listens, or a free port when it's taken.
  final int phonePort;

  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<HarnessApp> {
  // Every session, in sidebar order. [_active] has the keyboard. [_panes]
  // is the grid, when two or more were dragged in; it shows while the
  // active session is one of them.
  final _sessions = <Session>[];
  late Session _active;
  final _panes = <Session>[];
  var _made = 0;
  var _folded = false;

  // The mouse: what the button went down on, and the drag it became.
  _Hit? _pressed;
  _Drag? _drag;

  // The terminal's size at the last layout, for working out what the
  // mouse is over.
  var _width = 80;
  var _height = 24;

  Price? get _price => _settings.prices[component.model];

  late var _settings = Settings.load(component.settingsFile);
  var _settingsOpen = false;
  var _choice = 0;

  // The phone app's server and the copy of every session it's sent, once
  // /phone starts them.
  PhoneServer? _phone;
  PhoneMirror? _mirror;
  StreamSubscription<Map<String, dynamic>>? _phoneMessages;

  Agent _agent(
    FileHistory history, [
    Iterable<Message> conversation = const [],
  ]) => Agent(
    component.provider,
    [
      ...?component.sandbox?.tools(history: history),
      if (component.sandbox == null) ...fileTools(history: history),
      askUserTool,
    ],
    system: component.sandbox == null
        ? systemPrompt
        : '$systemPrompt\n\n$sandboxPrompt',
    conversation: conversation,
  );

  Session _newSession([Iterable<Message> conversation = const []]) {
    final history = FileHistory();
    final id = ++_made;
    return Session(
      id,
      'session $id',
      _agent(history, conversation),
      history,
      onChange: () {
        if (mounted) setState(() {});
      },
    )..setMood(Mood.waiting);
  }

  @override
  void initState() {
    super.initState();
    _active = _newSession();
    _sessions.add(_active);
  }

  @override
  void dispose() {
    _phoneMessages?.cancel();
    _phone?.close();
    for (final session in _sessions) {
      session.dispose();
    }
    super.dispose();
  }

  // ---- what's on screen ----

  bool get _sidebar => _sessions.length > 1;
  bool get _rail => _folded || _width < _railBelow;
  int get _sideWidth => !_sidebar ? 0 : (_rail ? _railWidth : _sidebarWidth);
  int get _mainLeft => 1 + (_sideWidth == 0 ? 0 : _sideWidth + 1);
  int get _mainWidth => _width - 1 - _mainLeft;

  /// The sessions on screen: the grid, or the active one alone.
  List<Session> get _shown =>
      _panes.length > 1 && _panes.contains(_active) ? _panes : [_active];

  /// Whether a drag from the sidebar would add a pane if dropped now.
  bool get _dropsIn {
    final drag = _drag;
    return drag != null &&
        !drag.fromPane &&
        drag.x >= _mainLeft &&
        _shown.length < 4 &&
        !_shown.contains(drag.session);
  }

  /// Whether a pane dragged to here would leave the grid.
  bool get _dropsOut {
    final drag = _drag;
    return drag != null && drag.fromPane && drag.x < _mainLeft - 1;
  }

  void _switchTo(Session session) => setState(() => _active = session);

  void _cycle(int step) {
    final at = _sessions.indexOf(_active);
    _switchTo(_sessions[(at + step) % _sessions.length]);
  }

  // Ctrl+Tab and Ctrl+Shift+Tab, like browser tabs. Terminals that keep
  // Ctrl+Tab for their own tabs still pass Shift+Tab through.
  bool _onKey(KeyboardEvent event) {
    if (event.logicalKey != LogicalKey.tab || _sessions.length < 2) {
      return false;
    }
    final ctrl = event.modifiers.ctrl, shift = event.modifiers.shift;
    if (!ctrl && !shift) return false;
    _cycle(ctrl && shift ? -1 : 1);
    return true;
  }

  // ---- the mouse ----

  _Hit? _hit(int x, int y) {
    final side = _sideWidth;
    if (side > 0 && x >= 1 && x < 1 + side) {
      // the « sits at the right end of the sidebar's top border; the rail's
      // whole top border is its »
      if (y == 0) return _rail || x >= side - 4 ? const _Fold() : null;
      final i = y - 1;
      return i < _sessions.length ? _Row(_sessions[i]) : null;
    }
    if (x < _mainLeft) return null;

    final shown = _shown;
    final boxes = _gridBoxes(shown.length, _mainWidth, _height);
    for (final (i, box) in boxes.indexed) {
      final dx = x - _mainLeft - box.x, dy = y - box.y;
      if (dx >= 0 && dx < box.w && dy >= 0 && dy < box.h) {
        return _Pane(shown[i], title: shown.length > 1 && dy == 0);
      }
    }
    return null;
  }

  void _onMouse(MouseEvent event) {
    if (event.button == MouseButton.wheelUp ||
        event.button == MouseButton.wheelDown) {
      return;
    }
    final (x, y) = (event.x, event.y);

    if (event.pressed && !event.isMotion) {
      _pressed = _hit(x, y);
    } else if (event.pressed && event.isMotion) {
      if (_drag case final drag?) {
        setState(
          () => drag
            ..x = x
            ..y = y,
        );
      } else if (_pressed case _Row(:final session)) {
        setState(() => _drag = _Drag(session, fromPane: false, x: x, y: y));
      } else if (_pressed case _Pane(:final session, title: true)) {
        setState(() => _drag = _Drag(session, fromPane: true, x: x, y: y));
      }
    } else if (!event.pressed && !event.isMotion) {
      final pressed = _pressed;
      _pressed = null;
      if (_drag case final drag?) {
        drag
          ..x = x
          ..y = y;
        _drop(drag);
        return;
      }
      switch (pressed) {
        case _Fold():
          setState(() => _folded = !_folded);
        case _Row(:final session) || _Pane(:final session):
          _switchTo(session);
        case null:
          break;
      }
    }
  }

  void _drop(_Drag drag) {
    setState(() {
      if (_dropsIn) {
        final grid = [..._shown]; // _shown can be _panes itself
        _panes
          ..clear()
          ..addAll([...grid, drag.session]);
      } else if (_dropsOut) {
        final wasActive = identical(_active, drag.session);
        _panes.remove(drag.session);
        if (_panes.length == 1) {
          if (wasActive) _active = _panes.single;
          _panes.clear();
        } else if (wasActive && _panes.isNotEmpty) {
          _active = _panes.first;
        }
      }
      _drag = null;
    });
  }

  // ---- prompts and commands ----

  Future<void> _submit(
    Session session,
    String prompt, {
    bool fromPhone = false,
  }) async {
    final text = prompt.trim();
    // while a session works, it can still open another session
    if (text.isEmpty || session.busy && !_anytime.contains(text)) return;
    if (fromPhone && _terminalOnly.contains(text)) return;
    if (!fromPhone) session.input.clear();

    switch (text) {
      case '/exit':
        await component.sandbox?.stop();
        shutdownApp();
        return;
      case '/clear':
        setState(() {
          session.history.clear();
          session.agent = _agent(session.history);
          session.entries.clear();
          session.context = 0;
          session.setMood(Mood.waiting);
        });
        return;
      case '/undo':
        _undo(session);
        return;
      case '/fork':
        _fork(session);
        return;
      case '/new':
        setState(() {
          final fresh = _newSession();
          _sessions.add(fresh);
          _active = fresh;
        });
        return;
      case '/settings':
        setState(() {
          _settingsOpen = true;
          _choice = _settings.theme.index;
        });
        return;
      case '/phone':
        await _startPhone(session);
        return;
    }
    if (text.startsWith('/new ')) {
      await _newFor(session, text.substring(5).trim());
      return;
    }
    await _run(session, text, fromPhone: fromPhone);
  }

  // Starts the phone app's server, once, and says how to connect.
  Future<void> _startPhone(Session session) async {
    if (_phone == null || _phone!.closed) {
      final phone = await PhoneServer.start(
        port: component.phonePort,
        onChange: () {
          if (mounted) setState(() {});
        },
      );
      final mirror = PhoneMirror(
        phone,
        () => _sessions,
        spent: (s) => _price == null ? null : dollars(s.spent),
      );
      phone.onConnect = mirror.hello;
      _phoneMessages?.cancel();
      _phoneMessages = phone.received.listen(
        (message) => mirror.receive(
          message,
          prompt: (target, text) => _submit(target, text, fromPhone: true),
        ),
      );
      _phone = phone;
      _mirror = mirror;
    }
    final phone = _phone!;
    final addresses = await PhoneServer.addresses();
    if (!mounted) return;
    setState(() {
      session.entries.add(const PromptEntry('/phone'));
      session.entries.add(
        NoteEntry(
          'In the phone app, connect to '
          '${addresses.isEmpty ? 'this computer' : addresses.first}:'
          '${phone.port} with the code ${phone.code}.',
          detail:
              'The phone has to be on the same Wi-Fi, or on Tailscale.'
              '${addresses.length > 1 ? ' Other addresses: ${addresses.skip(1).map((a) => '$a:${phone.port}').join(', ')}' : ''}',
        ),
      );
    });
  }

  Future<void> _run(
    Session session,
    String prompt, {
    bool echo = true,
    bool fromPhone = false,
  }) async {
    setState(() {
      if (!session.named && !prompt.startsWith('/')) {
        session
          ..name = sessionName(prompt)
          ..named = true;
      }
      if (echo) session.entries.add(PromptEntry(prompt, fromPhone: fromPhone));
      session.busy = true;
      session.setMood(Mood.working);
    });

    final events = prompt == '/compact'
        ? session.agent.compact()
        : session.agent.send(prompt);

    var failed = false;
    await for (final event in events) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case UsageReported(:final usage):
            session.context = usage.context;
            session.spent += _price?.cost(usage) ?? 0;
          case Compacted(:final after):
            session.context = after;
            session.entries.add(EventEntry(event));
          case AgentError():
            failed = true;
            session.entries.add(EventEntry(event));
          case Asked(:final question):
            session.entries.add(EventEntry(event));
            _ask(session, question);
          default:
            session.entries.add(EventEntry(event));
        }
      });
    }

    if (!mounted) return;
    setState(() {
      session.busy = false;
      session.setMood(failed ? Mood.error : Mood.done);
    });
  }

  /// "name 2", or the next number that's free.
  String _copyName(String name) {
    final base = name.replaceFirst(RegExp(r' \d+$'), '');
    for (var n = 2; ; n++) {
      final copy = '$base $n';
      if (!_sessions.any((s) => s.name == copy)) return copy;
    }
  }

  // A new session with a copy of this chat, next to it in the sidebar.
  void _fork(Session from) {
    setState(() {
      final fork = _newSession(from.agent.conversation)
        ..name = _copyName(from.name)
        ..named = true
        ..context = from.context;
      fork.entries
        ..addAll(from.entries)
        ..add(
          NoteEntry(
            'Forked from ${from.name}. From here on, each chat goes its own '
            'way.',
          ),
        );
      _sessions.insert(_sessions.indexOf(from) + 1, fork);
      _active = fork;
    });
  }

  // A new session for [prompt]. One call asks the model whether the prompt
  // needs this chat; if it does, the new session starts from a summary.
  Future<void> _newFor(Session from, String prompt) async {
    if (prompt.isEmpty) return;
    final fresh = _newSession()
      ..name = sessionName(prompt)
      ..named = true;
    setState(() {
      _sessions.add(fresh);
      _active = fresh;
      fresh.entries
        ..add(PromptEntry(prompt))
        ..add(NoteEntry('Asking Gemini whether this needs ${from.name}…'));
      fresh.busy = true;
      fresh.setMood(Mood.working);
    });

    final Handoff handoff;
    try {
      handoff = await from.agent.handoff(prompt);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        fresh.entries.add(EventEntry(AgentError(e.toString())));
        fresh.busy = false;
        fresh.setMood(Mood.error);
      });
      return;
    }
    if (!mounted) return;

    setState(() {
      if (handoff.usage case final usage?) {
        fresh.spent += _price?.cost(usage) ?? 0;
      }
      fresh.entries.removeLast();
      if (handoff.summary case final summary?) {
        fresh.agent = _agent(fresh.history, Agent.summarized(summary));
        fresh.entries.add(
          NoteEntry(
            'Gemini says this needs ${from.name}, so a summary of it came '
            'along:',
            detail: summary
                .replaceFirst('[CompactedSummaryFromModel]', '')
                .trim(),
          ),
        );
      } else if (from.agent.conversation.isEmpty) {
        fresh.entries.add(
          NoteEntry('${from.name} has no chat yet, so this starts fresh.'),
        );
      } else {
        fresh.entries.add(
          NoteEntry(
            "Gemini says this doesn't need ${from.name}, so it starts fresh.",
          ),
        );
      }
    });
    await _run(fresh, prompt, echo: false);
  }

  // Shows the picker until the question is answered, here or elsewhere.
  void _ask(Session session, Question question) {
    session
      ..question = question
      ..pick = 0
      ..typing = false
      ..setMood(Mood.needs);
    component.onQuestion?.call(question);
    question.answer.then((_) {
      if (!mounted || !identical(session.question, question)) return;
      setState(() {
        session
          ..question = null
          ..typing = false
          ..setMood(Mood.working);
        session.answerInput.clear();
      });
    });
  }

  bool _onAskKey(Session session, KeyboardEvent event) {
    final question = session.question!;
    final count = question.options.length + 1; // the options, then "else"

    void choose(int index) => index < question.options.length
        ? question.reply(question.options[index])
        : setState(() => session.typing = true);

    switch (event.logicalKey) {
      case LogicalKey.arrowUp:
        setState(() => session.pick = (session.pick - 1) % count);
      case LogicalKey.arrowDown:
        setState(() => session.pick = (session.pick + 1) % count);
      case LogicalKey.enter:
        choose(session.pick);
      default:
        final n = int.tryParse(event.character ?? '');
        if (n == null || n < 1 || n > count) return false;
        choose(n - 1);
    }
    return true;
  }

  void _submitAnswer(Session session, String answer) {
    if (answer.trim().isEmpty) {
      setState(() => session.typing = false); // back to the choices
      return;
    }
    session.question?.reply(answer.trim());
  }

  // Puts back the file the agent's last edit changed, and tells the model.
  void _undo(Session session) {
    final undo = session.history.undo();
    setState(() {
      session.entries
        ..add(const PromptEntry('/undo'))
        ..add(UndoEntry(undo));
      if (undo != null && undo.undone) {
        session.agent.note(undoNote(undo));
        session.setMood(Mood.undo);
      }
    });
  }

  bool _onSettingsKey(KeyboardEvent event) {
    final modes = AppThemeMode.values;

    switch (event.logicalKey) {
      case LogicalKey.arrowUp:
        setState(() => _choice = (_choice - 1) % modes.length);
      case LogicalKey.arrowDown:
        setState(() => _choice = (_choice + 1) % modes.length);
      case LogicalKey.enter:
        setState(() {
          _settings = _settings.copyWith(theme: modes[_choice]);
          _settingsOpen = false;
        });
        _settings.save(component.settingsFile);
      case LogicalKey.escape:
        setState(() => _settingsOpen = false);
      default:
        return false;
    }
    return true;
  }

  // ---- drawing ----

  @override
  Component build(BuildContext context) {
    final colors = _settings.theme.colors;

    // Painting every cell keeps a theme the same in any terminal, and gives
    // text that has no color of its own the theme's text color.
    return AppTheme(
      colors: colors,
      child: SizedBox.expand(
        child: ColoredBox(
          color: colors.primaryContainer,
          foregroundColor: colors.primary,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _width = constraints.maxWidth.toInt();
              _height = constraints.maxHeight.toInt();
              // the phones get whatever this frame changed
              if (_mirror case final mirror?) scheduleMicrotask(mirror.sync);
              return _screen(colors);
            },
          ),
        ),
      ),
    );
  }

  Component _screen(AppColorsTheme colors) {
    final shown = <Session?>[..._shown, if (_dropsIn) null];
    final boxes = _gridBoxes(shown.length, _mainWidth, _height);
    final drag = _drag;

    return MouseRegion(
      onHover: _onMouse,
      child: Focusable(
        focused: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            if (_sideWidth > 0)
              Positioned(
                left: 1,
                top: 0,
                width: _sideWidth.toDouble(),
                height: _height.toDouble(),
                child: _rail ? _railBox(colors) : _sidebarBox(colors),
              ),
            for (final (i, session) in shown.indexed)
              Positioned(
                left: (_mainLeft + boxes[i].x).toDouble(),
                top: boxes[i].y.toDouble(),
                width: boxes[i].w.toDouble(),
                height: boxes[i].h.toDouble(),
                child: session == null
                    ? _dropZone(colors)
                    : shown.length == 1
                    ? _single(session, colors)
                    : _pane(session, colors),
              ),
            if (drag != null)
              Positioned(
                left: min(drag.x + 1, _width - 4).toDouble(),
                top: drag.y.toDouble(),
                child: Text(
                  ' ${face(drag.session.mood, drag.session.frame)} '
                  '${drag.session.name} ',
                  style: TextStyle(
                    color: colors.primaryContainer,
                    backgroundColor: colors.accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _moodColor(Mood mood, AppColorsTheme colors) => switch (mood) {
    Mood.error => colors.error,
    Mood.undo => colors.tool,
    _ => colors.accent,
  };

  Component _sidebarBox(AppColorsTheme colors) {
    // the title runs along the top border: "Sessions ─── «"
    final dashes = _sidebarWidth - 6 - 'Sessions'.length - 3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: _dropsOut ? colors.accent : colors.outline,
          style: BoxBorderStyle.rounded,
        ),
        title: BorderTitle.rich(
          textSpan: TextSpan(
            children: [
              TextSpan(
                text: 'Sessions',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextSpan(
                text: ' ${'─' * dashes} ',
                style: TextStyle(color: colors.outline),
              ),
              TextSpan(
                text: '«',
                style: TextStyle(
                  color: colors.accent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final session in _sessions) _sessionRow(session, colors),
          Expanded(child: SizedBox()),
          if (_phone case final phone? when phone.connected)
            Text('● phone connected', style: TextStyle(color: colors.tool)),
          for (final hint in [
            _dropsOut ? 'drop here to unsplit' : 'drag a session in to split',
            'Ctrl+Tab or Shift+Tab  next',
            '/new  /fork',
          ])
            Text(
              hint,
              style: TextStyle(
                color: _dropsOut ? colors.accent : colors.secondary,
              ),
            ),
        ],
      ),
    );
  }

  Component _sessionRow(Session session, AppColorsTheme colors) {
    final active = identical(session, _active);
    final room = _sidebarWidth - 4 - 8 - session.status.length;
    final name = session.name.length > room
        ? '${session.name.substring(0, room - 1)}…'
        : session.name;
    final inGrid = _panes.length > 1 && _panes.contains(session);

    return Row(
      children: [
        Text(active ? '▸ ' : '  ', style: TextStyle(color: colors.accent)),
        Text(
          face(session.mood, session.frame),
          style: TextStyle(color: _moodColor(session.mood, colors)),
        ),
        Text(' '),
        Text(
          name,
          style: TextStyle(
            color: active
                ? colors.accent
                : inGrid
                ? colors.focus
                : colors.primary,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(' · ', style: TextStyle(color: colors.outline)),
        Text(
          session.status,
          style: TextStyle(
            color: session.mood == Mood.needs
                ? colors.accent
                : colors.secondary,
            fontWeight: session.mood == Mood.needs
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Component _railBox(AppColorsTheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: _dropsOut ? colors.accent : colors.outline,
          style: BoxBorderStyle.rounded,
        ),
        title: BorderTitle(
          text: '»',
          style: TextStyle(color: colors.accent, fontWeight: FontWeight.bold),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final session in _sessions)
            Row(
              children: [
                Text(
                  identical(session, _active) ? '▸' : ' ',
                  style: TextStyle(color: colors.accent),
                ),
                Text(
                  face(session.mood, session.frame),
                  style: TextStyle(color: _moodColor(session.mood, colors)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Component _dropZone(AppColorsTheme colors) {
    return Container(
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: colors.accent,
          style: BoxBorderStyle.dashed,
        ),
      ),
      child: Center(
        child: Text(
          'drop to split',
          style: TextStyle(color: colors.accent, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  /// One session on its own: Term's header, the chat, the input.
  // Each session's widgets get its key, so switching sessions never hands
  // one session's input or scroll position to another.
  Component _single(Session session, AppColorsTheme colors) {
    return Column(
      key: ValueKey(session),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(session, colors),
        Expanded(child: _transcript(session, colors)),
        _status(session, colors),
        _bottom(session, colors, boxed: true),
      ],
    );
  }

  /// One session in the grid: its Term, name and cost in the title.
  Component _pane(Session session, AppColorsTheme colors) {
    final active = identical(session, _active);
    return Container(
      key: ValueKey(session),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: active ? colors.accent : colors.outline,
          style: BoxBorderStyle.rounded,
        ),
        title: BorderTitle.rich(
          textSpan: TextSpan(
            children: [
              TextSpan(
                text: face(session.mood, session.frame),
                style: TextStyle(color: _moodColor(session.mood, colors)),
              ),
              TextSpan(
                text: ' ${session.name}',
                style: TextStyle(
                  color: active ? colors.accent : colors.primary,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              if (_price != null)
                TextSpan(
                  text: ' · ${dollars(session.spent)}',
                  style: TextStyle(color: colors.secondary),
                ),
            ],
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _transcript(session, colors)),
          _status(session, colors),
          _bottom(session, colors, boxed: false),
        ],
      ),
    );
  }

  Component _transcript(Session session, AppColorsTheme colors) {
    final entries = session.entries;
    return ListView.builder(
      reverse: true,
      controller: session.scroll,
      itemCount: entries.length,
      itemBuilder: (context, index) =>
          _entry(session, entries[entries.length - 1 - index], colors),
    );
  }

  // What's under the chat: the input, or the question's picker, or the
  // settings for the session that opened them.
  Component _bottom(
    Session session,
    AppColorsTheme colors, {
    required bool boxed,
  }) {
    final active = identical(session, _active);
    if (_settingsOpen && active) return _settingsPanel(colors);
    if (session.question != null && session.typing) {
      return _answerField(session, colors, active);
    }
    if (session.question != null) return _askPanel(session, colors, active);
    return _inputField(session, colors, active, boxed: boxed);
  }

  Component _inputField(
    Session session,
    AppColorsTheme colors,
    bool active, {
    required bool boxed,
  }) {
    final field = TextField(
      controller: session.input,
      focused: active,
      onSubmitted: (prompt) => _submit(session, prompt),
      placeholder: boxed
          ? 'Ask anything · /new /fork /undo /phone /compact /clear '
                '/settings /exit'
          : 'Ask anything',
      placeholderStyle: TextStyle(color: colors.secondary),
      style: TextStyle(color: colors.primary),
      cursorColor: colors.focus,
      decoration: boxed
          ? InputDecoration(
              border: BoxBorder.all(
                color: colors.focus,
                style: BoxBorderStyle.rounded,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 1),
            )
          : null,
    );
    if (boxed) return field;

    // in a pane: a line, then the input, inside the pane's own border
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(color: colors.outline),
        field,
      ],
    );
  }

  Component _answerField(Session session, AppColorsTheme colors, bool active) {
    return TextField(
      controller: session.answerInput,
      focused: active,
      onSubmitted: (answer) => _submitAnswer(session, answer),
      placeholder: 'Type your answer · Enter sends it · empty goes back',
      placeholderStyle: TextStyle(color: colors.secondary),
      style: TextStyle(color: colors.primary),
      cursorColor: colors.focus,
      decoration: InputDecoration(
        border: BoxBorder.all(
          color: colors.accent,
          style: BoxBorderStyle.rounded,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 1),
      ),
    );
  }

  Component _askPanel(Session session, AppColorsTheme colors, bool active) {
    return Focusable(
      focused: active,
      onKeyEvent: (event) => _onAskKey(session, event),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          border: BoxBorder.all(
            color: colors.accent,
            style: BoxBorderStyle.rounded,
          ),
        ),
        child: Text(
          '↑ ↓ choose · Enter answers · or press a number',
          style: TextStyle(color: colors.secondary),
        ),
      ),
    );
  }

  Component _settingsPanel(AppColorsTheme colors) {
    return Focusable(
      focused: true,
      onKeyEvent: _onSettingsKey,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          border: BoxBorder.all(
            color: colors.focus,
            style: BoxBorderStyle.rounded,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Settings',
              style: TextStyle(
                color: colors.accent,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text('Theme', style: TextStyle(color: colors.secondary)),
            for (final mode in AppThemeMode.values)
              Text(
                '${mode.index == _choice ? '›' : ' '} ${mode.label}'
                '${mode == _settings.theme ? ' (current)' : ''}',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: mode.index == _choice
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            const SizedBox(height: 1),
            Text(
              '↑ ↓ choose · enter apply · esc close',
              style: TextStyle(color: colors.secondary),
            ),
          ],
        ),
      ),
    );
  }

  Component _header(Session session, AppColorsTheme colors) {
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: colors.outline,
          style: BoxBorderStyle.rounded,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Term(mood: session.mood, frame: session.frame),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'coding_agent_in_dart',
                        style: TextStyle(
                          color: colors.accent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    ..._counters(session, colors),
                  ],
                ),
                Row(
                  children: [
                    Text(
                      '${component.model} · ${_cwd()}',
                      style: TextStyle(color: colors.secondary),
                    ),
                    if (component.sandbox case final box?)
                      Text(
                        box.running ? ' · ▣ sandboxed' : ' · sandbox off',
                        style: TextStyle(
                          color: box.running ? colors.tool : colors.error,
                        ),
                      ),
                    if (_phone case final phone? when !phone.closed)
                      Text(
                        phone.connected
                            ? ' · phone connected'
                            : ' · phone code ${phone.code}',
                        style: TextStyle(color: colors.tool),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Component> _counters(Session session, AppColorsTheme colors) {
    final label = TextStyle(color: colors.secondary);
    return [
      Text('context ', style: label),
      Text(
        '${grouped(session.context)} tok',
        style: TextStyle(color: colors.primary),
      ),
      Text('  spent ', style: label),
      Text(
        _price == null
            ? 'no price for ${component.model}'
            : dollars(session.spent),
        style: TextStyle(color: colors.accent, fontWeight: FontWeight.bold),
      ),
    ];
  }

  String _cwd() {
    final home = Platform.environment['HOME'];
    final path = Directory.current.path;
    return home != null && path.startsWith(home)
        ? '~${path.substring(home.length)}'
        : path;
  }

  Component _status(Session session, AppColorsTheme colors) {
    return SizedBox(
      height: 1,
      child: session.busy && session.question == null
          ? Text(
              '${face(Mood.working, session.frame)} Thinking…',
              style: TextStyle(color: colors.accent),
            )
          : const Text(''),
    );
  }

  Component _entry(Session session, Entry entry, AppColorsTheme colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: switch (entry) {
        PromptEntry(:final text, :final fromPhone) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text('> $text', style: TextStyle(color: colors.secondary)),
            ),
            if (fromPhone)
              Text('  from phone', style: TextStyle(color: colors.accent)),
          ],
        ),
        EventEntry(:final event) => _event(session, event, colors),
        UndoEntry(:final undo) => _undone(undo, colors),
        NoteEntry(:final text, :final detail) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('┃ $text', style: TextStyle(color: colors.tool)),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(detail, style: TextStyle(color: colors.secondary)),
              ),
          ],
        ),
      },
    );
  }

  Component _event(Session session, AgentEvent event, AppColorsTheme colors) {
    return switch (event) {
      AssistantText(:final text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('● ', style: TextStyle(color: colors.primary)),
          Expanded(
            child: MarkdownText(text.trim(), styleSheet: colors.markdown),
          ),
        ],
      ),
      ToolStarted(:final label, :final diff) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('┃ $label', style: TextStyle(color: colors.tool)),
          ..._diff(diff, colors),
        ],
      ),
      ToolFinished(:final output, :final failed) => _output(
        output,
        failed ? colors.error : colors.secondary,
      ),
      CompactionStarted() => Text(
        '┃ Summarizing conversation…',
        style: TextStyle(color: colors.secondary),
      ),
      Compacted(:final before, :final after) => Text(
        '┃ Compacted conversation from $before tokens to $after tokens',
        style: TextStyle(color: colors.tool),
      ),
      UsageReported() => const SizedBox(),
      Asked(:final question) => _asked(session, question, colors),
      AgentError(:final message) => Text(
        'Error: $message',
        style: TextStyle(color: colors.error),
      ),
    };
  }

  // A tool's output under it: its last lines, which is where a command's
  // result and errors are.
  Component _output(String output, Color color) {
    final lines = output.trimRight().split('\n');
    final shown = lines.length > _outputRows
        ? lines.sublist(lines.length - _outputRows)
        : lines;
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lines.length > _outputRows)
            Text(
              '⎿ … ${lines.length - _outputRows} lines above',
              style: TextStyle(color: color),
            ),
          for (final (i, line) in shown.indexed)
            Text(
              '${i == 0 && lines.length <= _outputRows ? '⎿ ' : '  '}$line',
              style: TextStyle(color: color),
            ),
        ],
      ),
    );
  }

  // The question, its choices while it waits (the recommended one first),
  // then the answer.
  Component _asked(Session session, Question question, AppColorsTheme colors) {
    final waiting = identical(question, session.question) && !question.answered;
    final options = [...question.options, if (waiting) 'Something else…'];
    final pick = session.typing ? -1 : session.pick;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '? ',
              style: TextStyle(
                color: colors.accent,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: Text(
                question.text,
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        if (!waiting)
          Text(
            '  ✓ ${question.chosen ?? ''}',
            style: TextStyle(color: colors.tool),
          )
        else
          for (final (i, option) in options.indexed)
            Row(
              children: [
                Text(
                  i == pick ? '  ❯ ' : '    ',
                  style: TextStyle(color: colors.accent),
                ),
                Text(
                  '${i + 1}. $option',
                  style: TextStyle(
                    color: i == pick ? colors.accent : colors.primary,
                    fontWeight: i == pick ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                if (i == 0)
                  Text(' (recommended)', style: TextStyle(color: colors.tool)),
              ],
            ),
      ],
    );
  }

  Component _undone(Undo? undo, AppColorsTheme colors) {
    final note = TextStyle(color: colors.secondary);
    if (undo == null) return Text('┃ Nothing to undo.', style: note);
    if (undo.error case final error?) {
      return Text(
        'Error: could not undo ${undo.path}: $error',
        style: TextStyle(color: colors.error),
      );
    }
    if (undo.changedSince) {
      return Text(
        '┃ ${undo.path} changed after that edit, so /undo left it as it is.',
        style: note,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '↺ Undid UpdateFile(path: ${undo.path})',
          style: TextStyle(color: colors.tool),
        ),
        ..._diff(undo.diff, colors),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            undo.deleted
                ? 'That edit created the file, so it is deleted. The model '
                      'was told.'
                : 'The model was told this edit was undone.',
            style: note,
          ),
        ),
      ],
    );
  }

  List<Component> _diff(List<DiffLine> diff, AppColorsTheme colors) {
    final width = diff.fold(0, (w, line) => max(w, '${line.number}'.length));
    return [
      for (final line in diff.take(_maxDiffLines))
        _diffLine(line, width, colors),
      if (diff.length > _maxDiffLines)
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            '… +${diff.length - _maxDiffLines} lines',
            style: TextStyle(color: colors.secondary),
          ),
        ),
    ];
  }

  Component _diffLine(DiffLine line, int width, AppColorsTheme colors) {
    final number = '${line.number}'.padLeft(width);
    final (text, background) = switch (line.change) {
      Change.added => ('$number + ${line.text}', colors.added),
      Change.removed => ('$number - ${line.text}', colors.removed),
      Change.same => ('$number   ${line.text}', null),
      Change.skipped => ('⋮'.padLeft(width), null),
    };

    return Container(
      margin: const EdgeInsets.only(left: 2),
      color: background,
      child: Text(
        text.replaceAll('\t', '  '),
        style: TextStyle(
          color: background == null ? colors.secondary : colors.primary,
        ),
      ),
    );
  }
}
