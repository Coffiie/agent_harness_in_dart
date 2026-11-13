import 'package:flutter/material.dart';

import 'link.dart';
import 'sessions_screen.dart';
import 'term.dart';

/// One session's transcript, with a box to send it prompts.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.link, required this.id});

  final Link link;
  final int id;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();

  void _send(SessionInfo session) {
    final text = _input.text.trim();
    if (text.isEmpty || session.busy) return;
    widget.link.prompt(session.id, text);
    _input.clear();
    // out of the way, so the whole screen shows the session working
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.link,
    builder: (context, _) {
      final link = widget.link;
      final session = link.session(widget.id);
      // newest at the bottom, and the list starts there
      final entries = [
        for (final entry in link.entries(widget.id).reversed)
          if (entry['kind'] != 'usage') entry,
      ];
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(
            children: [
              if (session != null) Term(mood: session.mood),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session?.name ?? 'Gone',
                      style: mono.copyWith(fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (session != null)
                      Text(
                        [session.status, ?session.spent].join(' · '),
                        style: mono.copyWith(
                          fontSize: 12,
                          color: Graphite.secondary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            if (link.closed) const Disconnected(),
            Expanded(
              child: ListView.builder(
                reverse: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                itemCount: entries.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: EntryView(entry: entries[i], link: link),
                ),
              ),
            ),
            if (session != null && !link.closed) _box(session),
          ],
        ),
      );
    },
  );

  Widget _box(SessionInfo session) => SafeArea(
    top: false,
    child: Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Graphite.surface)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('prompt'),
              controller: _input,
              style: mono,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(session),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: session.busy
                    ? 'Term is working…'
                    : 'Ask anything, or /new /fork /undo',
              ),
            ),
          ),
          IconButton(
            key: const Key('send'),
            onPressed: session.busy ? null : () => _send(session),
            icon: const Icon(Icons.arrow_upward_rounded),
            color: Graphite.accent,
            disabledColor: Graphite.outline,
          ),
        ],
      ),
    ),
  );
}

/// One transcript entry, drawn like the TUI draws it.
class EntryView extends StatelessWidget {
  const EntryView({super.key, required this.entry, required this.link});

  final Map<String, dynamic> entry;
  final Link link;

  @override
  Widget build(BuildContext context) => switch (entry['kind']) {
    'prompt' => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            '> ${entry['text']}',
            style: mono.copyWith(color: Graphite.secondary),
          ),
        ),
        if (entry['fromPhone'] == true)
          Text(
            ' from phone',
            style: mono.copyWith(color: Graphite.accent, fontSize: 11),
          )
        else if (entry['from'] case final String from)
          Text(
            ' from $from',
            style: mono.copyWith(color: Graphite.accent, fontSize: 11),
          ),
      ],
    ),
    'reply' => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('● ', style: mono),
        Expanded(child: SelectableText(entry['text'] as String, style: mono)),
      ],
    ),
    'tool' => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('┃ ${entry['label']}', style: mono.copyWith(color: Graphite.tool)),
        if ((entry['diff'] as List).isNotEmpty)
          Diff(lines: (entry['diff'] as List).cast<Map<String, dynamic>>()),
      ],
    ),
    'output' => Output(
      text: entry['text'] as String,
      failed: entry['failed'] == true,
    ),
    'error' => Text(
      'Error: ${entry['text']}',
      style: mono.copyWith(color: Graphite.error),
    ),
    'question' => QuestionCard(entry: entry, link: link),
    _ => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '┃ ${entry['text']}',
          style: mono.copyWith(color: Graphite.secondary),
        ),
        if (entry['detail'] case final String detail)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: Text(
              detail,
              style: mono.copyWith(color: Graphite.secondary, fontSize: 12),
            ),
          ),
      ],
    ),
  };
}

/// A tool's output under it: its last lines, red when it failed.
class Output extends StatelessWidget {
  const Output({super.key, required this.text, required this.failed});

  static const rows = 12;

  final String text;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final cut = lines.length - rows;
    return Padding(
      padding: const EdgeInsets.only(left: 14, top: 2),
      child: Text(
        [
          if (cut > 0) '… $cut lines above',
          ...lines.skip(cut > 0 ? cut : 0),
        ].join('\n'),
        style: mono.copyWith(
          fontSize: 12,
          color: failed ? Graphite.error : Graphite.secondary,
        ),
      ),
    );
  }
}

/// A file edit's lines, added ones green and removed ones red, scrolling
/// sideways rather than wrapping so the code keeps its shape.
class Diff extends StatelessWidget {
  const Diff({super.key, required this.lines});

  final List<Map<String, dynamic>> lines;

  @override
  Widget build(BuildContext context) {
    final width = lines
        .map((l) => '${l['n']}'.length)
        .fold(1, (a, b) => a > b ? a : b);
    final style = mono.copyWith(fontSize: 12, height: 1.4);
    return Container(
      margin: const EdgeInsets.only(top: 4, left: 2),
      decoration: BoxDecoration(
        border: Border.all(color: Graphite.surface),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final line in lines)
                Container(
                  color: switch (line['change']) {
                    'added' => Graphite.added,
                    'removed' => Graphite.removed,
                    _ => null,
                  },
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    switch (line['change']) {
                      'skipped' => '⋮'.padLeft(width),
                      final change =>
                        '${'${line['n']}'.padLeft(width)} '
                            '${change == 'added'
                                ? '+'
                                : change == 'removed'
                                ? '-'
                                : ' '} '
                            '${(line['text'] as String).replaceAll('\t', '  ')}',
                    },
                    style: style.copyWith(
                      color:
                          line['change'] == 'added' ||
                              line['change'] == 'removed'
                          ? Graphite.primary
                          : Graphite.secondary,
                    ),
                    softWrap: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the model asked with askUser. The option it recommends comes first,
/// labelled and already picked, so answering it is one tap on Answer. Once
/// anyone answers, here or in the TUI, it shows the choice.
class QuestionCard extends StatefulWidget {
  const QuestionCard({super.key, required this.entry, required this.link});

  final Map<String, dynamic> entry;
  final Link link;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  var _pick = 0;
  final _own = TextEditingController();

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  void _answer(List<String> options) {
    final own = _own.text.trim();
    widget.link.answer(
      widget.entry['id'] as int,
      own.isNotEmpty ? own : options[_pick],
    );
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final options = (widget.entry['options'] as List).cast<String>();
    final chosen = widget.entry['chosen'] as String?;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: chosen == null ? Graphite.accent : Graphite.outline,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '? ${widget.entry['text']}',
            style: mono.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (chosen != null)
            Text('✓ $chosen', style: mono.copyWith(color: Graphite.tool))
          else ...[
            for (final (i, option) in options.indexed)
              _Option(
                key: Key('option $i'),
                text: option,
                recommended: i == 0,
                picked: i == _pick && _own.text.trim().isEmpty,
                onTap: () => setState(() {
                  _pick = i;
                  _own.clear();
                }),
              ),
            TextField(
              key: const Key('own answer'),
              controller: _own,
              style: mono.copyWith(fontSize: 13),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Or write your own',
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: const Key('answer'),
              onPressed: () => _answer(options),
              child: Text(
                'Answer',
                style: mono.copyWith(
                  color: Graphite.background,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.text,
    required this.recommended,
    required this.picked,
    required this.onTap,
  });

  final String text;
  final bool recommended;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: picked ? Graphite.surface : null,
          border: Border.all(
            color: picked ? Graphite.accent : Graphite.outline,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Text(
              picked ? '● ' : '○ ',
              style: mono.copyWith(color: Graphite.accent),
            ),
            Expanded(child: Text(text, style: mono)),
            if (recommended)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Graphite.accent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Recommended',
                  style: mono.copyWith(
                    color: Graphite.background,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
