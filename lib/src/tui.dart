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
import 'model_provider.dart';
import 'settings.dart';
import 'term.dart';
import 'tools.dart';

const _maxDiffLines = 14;

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
    'and why.';

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

class HarnessApp extends StatefulComponent {
  const HarnessApp({
    super.key,
    required this.provider,
    required this.model,
    this.settingsFile,
  });

  final ModelProvider provider;
  final String model;

  /// Where /settings saves its choices. With none, they last until the app
  /// quits.
  final File? settingsFile;

  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<HarnessApp> {
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

  late var _settings = Settings.load(component.settingsFile);
  var _settingsOpen = false;
  var _choice = 0;

  Agent _newAgent() =>
      Agent(component.provider, fileTools, system: systemPrompt);

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
      Mood.done || Mood.error => null,
    };
    _ticker = every == null
        ? null
        : Timer.periodic(every, (_) => setState(() => _frame++));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _input.dispose();
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
          _agent = _newAgent();
          _entries.clear();
          _setMood(Mood.waiting);
        });
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
      if (event is AgentError) failed = true;
      setState(() => _entries.add(EventEntry(event)));
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _setMood(failed ? Mood.error : Mood.done);
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
          _settings = Settings(theme: modes[_choice]);
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
          if (_settingsOpen) _settingsPanel(colors) else _inputField(colors),
        ],
      ),
    );
  }

  Component _inputField(AppColorsTheme colors) {
    return TextField(
      controller: _input,
      focused: true,
      onSubmitted: _submit,
      placeholder: 'Ask anything, or /compact, /clear, /settings, /exit',
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
                Text(
                  'coding_agent_in_dart',
                  style: TextStyle(
                    color: colors.accent,
                    fontWeight: FontWeight.bold,
                  ),
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
      child: _busy
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
      AgentError(:final message) => Text(
        'Error: $message',
        style: TextStyle(color: colors.error),
      ),
    };
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
