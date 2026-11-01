import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:nocterm/nocterm.dart';

import 'agent.dart';
import 'diff.dart';
import 'events.dart';
import 'model_provider.dart';
import 'tools.dart';

const _accent = Color.fromRGB(242, 182, 148);
const _text = Color.fromRGB(243, 237, 230);
const _muted = Color.fromRGB(169, 178, 176);
const _ok = Color.fromRGB(167, 207, 194);
const _bad = Color.fromRGB(229, 120, 107);
const _addedBg = Color.fromRGB(33, 66, 45);
const _removedBg = Color.fromRGB(84, 36, 36);

const _maxDiffLines = 14;

const _spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

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
  const HarnessApp({super.key, required this.provider, required this.model});

  final ModelProvider provider;
  final String model;

  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<HarnessApp> {
  late var _agent = Agent(component.provider, fileTools);
  final _entries = <Entry>[];
  final _input = TextEditingController();
  final _scroll = AutoScrollController();

  Timer? _ticker;
  var _frame = 0;

  bool get _busy => _ticker != null;

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
          _agent = Agent(component.provider, fileTools);
          _entries.clear();
        });
        return;
    }

    setState(() {
      _entries.add(PromptEntry(prompt));
      _ticker = Timer.periodic(const Duration(milliseconds: 80), (_) {
        setState(() => _frame++);
      });
    });

    final events = prompt.trim() == '/compact'
        ? _agent.compact()
        : _agent.send(prompt);

    await for (final event in events) {
      if (!mounted) return;
      setState(() => _entries.add(EventEntry(event)));
    }

    if (!mounted) return;
    setState(() {
      _ticker?.cancel();
      _ticker = null;
    });
  }

  @override
  Component build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: ListView.builder(
              reverse: true,
              controller: _scroll,
              itemCount: _entries.length,
              itemBuilder: (context, index) =>
                  _entry(_entries[_entries.length - 1 - index]),
            ),
          ),
          _status(),
          TextField(
            controller: _input,
            focused: true,
            onSubmitted: _submit,
            placeholder: 'Ask anything, or /compact, /clear, /exit',
            placeholderStyle: const TextStyle(color: _muted),
            style: const TextStyle(color: _text),
            cursorColor: _accent,
            decoration: InputDecoration(
              border: BoxBorder.all(
                color: _accent,
                style: BoxBorderStyle.rounded,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 1),
            ),
          ),
        ],
      ),
    );
  }

  Component _header() {
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        border: BoxBorder.all(color: _muted, style: BoxBorderStyle.rounded),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '✻ coding_agent_in_dart',
            style: const TextStyle(color: _accent, fontWeight: FontWeight.bold),
          ),
          Text(
            '${component.model} · ${_cwd()}',
            style: const TextStyle(color: _muted),
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

  Component _status() {
    return SizedBox(
      height: 1,
      child: _busy
          ? Text(
              '${_spinner[_frame % _spinner.length]} Thinking…',
              style: const TextStyle(color: _accent),
            )
          : const Text(''),
    );
  }

  Component _entry(Entry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: switch (entry) {
        PromptEntry(:final text) => Text(
          '> $text',
          style: const TextStyle(color: _muted),
        ),
        EventEntry(:final event) => _event(event),
      },
    );
  }

  Component _event(AgentEvent event) {
    return switch (event) {
      AssistantText(:final text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('● ', style: TextStyle(color: _text)),
          Expanded(child: MarkdownText(text.trim())),
        ],
      ),
      ToolStarted(:final label, :final diff) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('┃ $label', style: const TextStyle(color: _ok)),
          ..._diff(diff),
        ],
      ),
      CompactionStarted() => const Text(
        '┃ Summarizing conversation…',
        style: TextStyle(color: _muted),
      ),
      Compacted(:final before, :final after) => Text(
        '┃ Compacted conversation from $before tokens to $after tokens',
        style: const TextStyle(color: _ok),
      ),
      AgentError(:final message) => Text(
        'Error: $message',
        style: const TextStyle(color: _bad),
      ),
    };
  }

  List<Component> _diff(List<DiffLine> diff) {
    final width = diff.fold(0, (w, line) => max(w, '${line.number}'.length));
    return [
      for (final line in diff.take(_maxDiffLines)) _diffLine(line, width),
      if (diff.length > _maxDiffLines)
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            '… +${diff.length - _maxDiffLines} lines',
            style: const TextStyle(color: _muted),
          ),
        ),
    ];
  }

  Component _diffLine(DiffLine line, int width) {
    final number = '${line.number}'.padLeft(width);
    final (text, background) = switch (line.change) {
      Change.added => ('$number + ${line.text}', _addedBg),
      Change.removed => ('$number - ${line.text}', _removedBg),
      Change.same => ('$number   ${line.text}', null),
      Change.skipped => ('⋮'.padLeft(width), null),
    };

    return Container(
      margin: const EdgeInsets.only(left: 2),
      color: background,
      child: Text(
        text.replaceAll('\t', '  '),
        style: TextStyle(color: background == null ? _muted : _text),
      ),
    );
  }
}
