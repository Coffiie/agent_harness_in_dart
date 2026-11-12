import 'dart:async';

import 'package:nocterm/nocterm.dart';

import 'agent.dart';
import 'events.dart';
import 'history.dart';
import 'question.dart';
import 'term.dart';

sealed class Entry {
  const Entry();
}

class PromptEntry extends Entry {
  const PromptEntry(this.text, {this.fromPhone = false});

  final String text;

  /// Sent from the phone app.
  final bool fromPhone;
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

/// A line from the harness itself, like where a fork came from.
class NoteEntry extends Entry {
  const NoteEntry(this.text, {this.detail});

  final String text;

  /// More below it, like the summary /new carried over.
  final String? detail;
}

// Words that say little about what a session is for.
const _filler = {
  'a', 'about', 'add', 'all', 'also', 'an', 'and', 'are', 'as', 'ask', //
  'at', 'be', 'build', 'by', 'can', 'could', 'create', 'do', 'does', //
  'first', 'for', 'from', 'how', 'i', 'implement', 'in', 'into', 'is', //
  'it', 'just', 'let', "let's", 'make', 'me', 'my', 'new', 'now', 'of', //
  'on', 'one', 'or', 'please', 'should', 'so', 'some', 'something', //
  'that', 'the', 'then', 'this', 'to', 'us', 'we', 'what', 'whether', //
  'which', 'with', 'would', 'write', 'you', 'your',
};

/// A short name for a session, from its first prompt: its first words
/// that say something, up to 16 characters. A path keeps only its file
/// name.
String sessionName(String prompt) {
  final words = [
    for (final word in prompt.trim().split(RegExp(r'\s+')))
      word
          .split('/')
          .last
          .replaceAll(RegExp(r'^\W+|\W+$'), ''), // punctuation around it
  ].where((w) => w.isNotEmpty && !_filler.contains(w.toLowerCase()));

  var name = '';
  for (final word in words) {
    final longer = name.isEmpty ? word : '$name $word';
    if (longer.length > 16) break;
    name = longer;
  }
  if (name.isNotEmpty) return name;

  final first = words.firstOrNull ?? prompt.trim();
  return first.length > 16 ? '${first.substring(0, 15)}…' : first;
}

/// One chat in the TUI, with its own agent, transcript, input and Term.
/// The app keeps several and shows one, or a grid of them.
class Session {
  Session(
    this.id,
    this.name,
    this.agent,
    this.history, {
    required this.onChange,
  });

  /// Unique for the app's lifetime, so the phone can tell sessions apart.
  final int id;

  /// "session 2" until the first prompt names it.
  String name;
  var named = false;

  Agent agent;

  /// Every edit this session's agent makes, so /undo can take it back.
  final FileHistory history;

  /// Called when something on screen changes without the app asking, like
  /// Term's next frame.
  final void Function() onChange;

  final entries = <Entry>[];
  final input = TextEditingController();
  final scroll = AutoScrollController();

  // Term's animation: [frame] counts ticks of [_ticker], which runs while
  // Term blinks or works and stops for the other faces.
  Timer? _ticker;
  var frame = 0;
  var mood = Mood.waiting;
  var busy = false;

  // The header's counters: the chat's size after the last call, and the
  // dollars this session has spent. /compact and /clear shrink the first;
  // the second only goes up.
  var context = 0;
  var spent = 0.0;

  // The question the model is waiting on, if any. [pick] is the
  // highlighted choice, where one past the last option is "Something
  // else…", and [typing] means the user is writing their own answer.
  Question? question;
  var pick = 0;
  var typing = false;
  final answerInput = TextEditingController();

  /// What the sidebar says about it.
  String get status => switch (mood) {
    Mood.waiting => 'idle',
    Mood.working => 'working',
    Mood.done => 'done',
    Mood.error => 'error',
    Mood.undo => 'undone',
    Mood.needs => 'needs you',
  };

  void setMood(Mood next) {
    mood = next;
    frame = 0;
    _ticker?.cancel();
    final every = switch (mood) {
      Mood.waiting => const Duration(milliseconds: 600),
      Mood.working => const Duration(milliseconds: 250),
      Mood.done || Mood.error || Mood.undo || Mood.needs => null,
    };
    _ticker = every == null
        ? null
        : Timer.periodic(every, (_) {
            frame++;
            onChange();
          });
  }

  void dispose() {
    _ticker?.cancel();
    input.dispose();
    answerInput.dispose();
    scroll.dispose();
  }
}
