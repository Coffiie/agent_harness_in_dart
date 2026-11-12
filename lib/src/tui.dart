import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:nocterm/nocterm.dart';

import 'agent.dart';
import 'design_system/colors.dart';
import 'design_system/extensions.dart';
import 'design_system/theme.dart';
import 'diff.dart';
import 'events.dart';
import 'history.dart';
import 'model_provider.dart';
import 'question.dart';
import 'settings.dart';
import 'term.dart';
import 'tools.dart';
import 'usage.dart';

const _maxDiffLines = 14;

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

sealed class Entry {
  const Entry();
}

class PromptEntry extends Entry {
  const PromptEntry(this.text);

  final String text;
}

class EventEntry extends Entry {
  const EventEntry(this.event);

  final AgentEvent event;
}

/// What /undo did, or null when there was nothing to undo.
class UndoEntry extends Entry {
  const UndoEntry(this.undo);

  final Undo? undo;
}

/// What the model is told after /undo, so it doesn't go on as if its edit
/// were still there.
String undoNote(Undo undo) => undo.deleted
    ? '[The user ran /undo. Your edit created ${undo.path}, so that file '
          'was deleted.]'
    : '[The user ran /undo. Your last edit to ${undo.path} was undone, and '
          'the file is back to what it was before that edit. Read it again '
          'before you change it.]';

class HarnessApp extends StatefulComponent {
  const HarnessApp({
    super.key,
    required this.provider,
    required this.model,
    this.settingsFile,
    this.onQuestion,
  });

  final ModelProvider provider;
  final String model;

  /// Where /settings saves its choices. With none, they last until the app
  /// quits.
  final File? settingsFile;

  /// Called with each question the model asks, so something else can
  /// answer it too. The first answer wins.
  final void Function(Question question)? onQuestion;

  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<HarnessApp> {
  // every edit the agent makes, so /undo can take it back
  final _history = FileHistory();
  late var _agent = _newAgent();
  final _entries = <Entry>[];
  final _input = TextEditingController();
  final _scroll = AutoScrollController();

  // Term's animation: [_frame] counts ticks of [_ticker], which runs while
  // Term blinks or works and stops for the done and error faces.
  Timer? _ticker;
  var _frame = 0;
  var _mood = Mood.waiting;
  var _busy = false;

  // The header's counters: the chat's size after the last call, and the
  // dollars spent since the app started. /compact and /clear shrink the
  // first; the second only goes up.
  var _context = 0;
  var _spent = 0.0;

  Price? get _price => _settings.prices[component.model];

  // The question the model is waiting on, if any. [_pick] is the
  // highlighted choice, where one past the last option is "Something
  // else…", and [_typing] means the user is writing their own answer.
  Question? _question;
  var _pick = 0;
  var _typing = false;
  final _answerInput = TextEditingController();

  late var _settings = Settings.load(component.settingsFile);
  var _settingsOpen = false;
  var _choice = 0;

  Agent _newAgent() => Agent(component.provider, [
    ...fileTools(history: _history),
    askUserTool,
  ], system: systemPrompt);

  @override
  void initState() {
    super.initState();
    _animate();
  }

  void _setMood(Mood mood) {
    _mood = mood;
    _frame = 0;
    _animate();
  }

  void _animate() {
    _ticker?.cancel();
    final every = switch (_mood) {
      Mood.waiting => const Duration(milliseconds: 600),
      Mood.working => const Duration(milliseconds: 250),
      Mood.done || Mood.error || Mood.undo || Mood.needs => null,
    };
    _ticker = every == null
        ? null
        : Timer.periodic(every, (_) => setState(() => _frame++));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _input.dispose();
    _answerInput.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _submit(String prompt) async {
    if (prompt.trim().isEmpty || _busy) return;
    _input.clear();

    switch (prompt.trim()) {
      case '/exit':
        shutdownApp();
        return;
      case '/clear':
        setState(() {
          _history.clear();
          _agent = _newAgent();
          _entries.clear();
          _context = 0;
          _setMood(Mood.waiting);
        });
        return;
      case '/undo':
        _undo();
        return;
      case '/settings':
        setState(() {
          _settingsOpen = true;
          _choice = _settings.theme.index;
        });
        return;
    }

    setState(() {
      _entries.add(PromptEntry(prompt));
      _busy = true;
      _setMood(Mood.working);
    });

    final events = prompt.trim() == '/compact'
        ? _agent.compact()
        : _agent.send(prompt);

    var failed = false;
    await for (final event in events) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case UsageReported(:final usage):
            _context = usage.context;
            _spent += _price?.cost(usage) ?? 0;
          case Compacted(:final after):
            _context = after;
            _entries.add(EventEntry(event));
          case AgentError():
            failed = true;
            _entries.add(EventEntry(event));
          case Asked(:final question):
            _entries.add(EventEntry(event));
            _ask(question);
          default:
            _entries.add(EventEntry(event));
        }
      });
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _setMood(failed ? Mood.error : Mood.done);
    });
  }

  // Shows the picker until the question is answered, here or elsewhere.
  void _ask(Question question) {
    _question = question;
    _pick = 0;
    _typing = false;
    _setMood(Mood.needs);
    component.onQuestion?.call(question);
    question.answer.then((_) {
      if (!mounted || !identical(_question, question)) return;
      setState(() {
        _question = null;
        _typing = false;
        _answerInput.clear();
        _setMood(Mood.working);
      });
    });
  }

  bool _onAskKey(KeyboardEvent event) {
    final question = _question!;
    final count = question.options.length + 1; // the options, then "else"

    void choose(int index) => index < question.options.length
        ? question.reply(question.options[index])
        : setState(() => _typing = true);

    switch (event.logicalKey) {
      case LogicalKey.arrowUp:
        setState(() => _pick = (_pick - 1) % count);
      case LogicalKey.arrowDown:
        setState(() => _pick = (_pick + 1) % count);
      case LogicalKey.enter:
        choose(_pick);
      default:
        final n = int.tryParse(event.character ?? '');
        if (n == null || n < 1 || n > count) return false;
        choose(n - 1);
    }
    return true;
  }

  void _submitAnswer(String answer) {
    if (answer.trim().isEmpty) {
      setState(() => _typing = false); // back to the choices
      return;
    }
    _question?.reply(answer.trim());
  }

  // Puts back the file the agent's last edit changed, and tells the model.
  void _undo() {
    final undo = _history.undo();
    setState(() {
      _entries
        ..add(const PromptEntry('/undo'))
        ..add(UndoEntry(undo));
      if (undo != null && undo.undone) {
        _agent.note(undoNote(undo));
        _setMood(Mood.undo);
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
          child: Builder(builder: _screen),
        ),
      ),
    );
  }

  Component _screen(BuildContext context) {
    final colors = context.theme.colors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(colors),
          Expanded(
            child: ListView.builder(
              reverse: true,
              controller: _scroll,
              itemCount: _entries.length,
              itemBuilder: (context, index) =>
                  _entry(_entries[_entries.length - 1 - index], colors),
            ),
          ),
          _status(colors),
          if (_settingsOpen)
            _settingsPanel(colors)
          else if (_question != null && _typing)
            _answerField(colors)
          else if (_question != null)
            _askPanel(colors)
          else
            _inputField(colors),
        ],
      ),
    );
  }

  Component _inputField(AppColorsTheme colors) {
    return TextField(
      controller: _input,
      focused: true,
      onSubmitted: _submit,
      placeholder: 'Ask anything, or /undo, /compact, /clear, /settings, /exit',
      placeholderStyle: TextStyle(color: colors.secondary),
      style: TextStyle(color: colors.primary),
      cursorColor: colors.focus,
      decoration: InputDecoration(
        border: BoxBorder.all(
          color: colors.focus,
          style: BoxBorderStyle.rounded,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 1),
      ),
    );
  }

  Component _answerField(AppColorsTheme colors) {
    return TextField(
      controller: _answerInput,
      focused: true,
      onSubmitted: _submitAnswer,
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

  Component _askPanel(AppColorsTheme colors) {
    return Focusable(
      focused: true,
      onKeyEvent: _onAskKey,
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

  Component _header(AppColorsTheme colors) {
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
          Term(mood: _mood, frame: _frame),
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
                    ..._counters(colors),
                  ],
                ),
                Text(
                  '${component.model} · ${_cwd()}',
                  style: TextStyle(color: colors.secondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Component> _counters(AppColorsTheme colors) {
    final label = TextStyle(color: colors.secondary);
    return [
      Text('context ', style: label),
      Text('${grouped(_context)} tok', style: TextStyle(color: colors.primary)),
      Text('  spent ', style: label),
      Text(
        _price == null ? 'no price for ${component.model}' : dollars(_spent),
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

  Component _status(AppColorsTheme colors) {
    return SizedBox(
      height: 1,
      child: _busy && _question == null
          ? Text(
              '${face(Mood.working, _frame)} Thinking…',
              style: TextStyle(color: colors.accent),
            )
          : const Text(''),
    );
  }

  Component _entry(Entry entry, AppColorsTheme colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: switch (entry) {
        PromptEntry(:final text) => Text(
          '> $text',
          style: TextStyle(color: colors.secondary),
        ),
        EventEntry(:final event) => _event(event, colors),
        UndoEntry(:final undo) => _undone(undo, colors),
      },
    );
  }

  Component _event(AgentEvent event, AppColorsTheme colors) {
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
      CompactionStarted() => Text(
        '┃ Summarizing conversation…',
        style: TextStyle(color: colors.secondary),
      ),
      Compacted(:final before, :final after) => Text(
        '┃ Compacted conversation from $before tokens to $after tokens',
        style: TextStyle(color: colors.tool),
      ),
      UsageReported() => const SizedBox(),
      Asked(:final question) => _asked(question, colors),
      AgentError(:final message) => Text(
        'Error: $message',
        style: TextStyle(color: colors.error),
      ),
    };
  }

  // The question, its choices while it waits (the recommended one first),
  // then the answer.
  Component _asked(Question question, AppColorsTheme colors) {
    final waiting = identical(question, _question) && !question.answered;
    final options = [...question.options, if (waiting) 'Something else…'];
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
                  i == _pick && !_typing ? '  ❯ ' : '    ',
                  style: TextStyle(color: colors.accent),
                ),
                Text(
                  '${i + 1}. $option',
                  style: TextStyle(
                    color: i == _pick && !_typing
                        ? colors.accent
                        : colors.primary,
                    fontWeight: i == _pick && !_typing
                        ? FontWeight.bold
                        : FontWeight.normal,
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
