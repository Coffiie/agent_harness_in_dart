import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One session on the computer, as the sidebar shows it.
class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.name,
    required this.status,
    required this.mood,
    required this.busy,
    this.spent,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) => SessionInfo(
    id: json['id'] as int,
    name: json['name'] as String,
    status: json['status'] as String,
    mood: json['mood'] as String,
    busy: json['busy'] as bool,
    spent: json['spent'] as String?,
  );

  final int id;
  final String name;

  /// idle, working, done, error, undone or needs you.
  final String status;

  /// Term's mood: waiting, working, done, error, undo or needs.
  final String mood;
  final bool busy;

  /// What it has spent, like "$0.0012", when the TUI knows the price.
  final String? spent;
}

/// The connection to the TUI on the computer. It keeps the session list and
/// each session's transcript up to date, and sends prompts and answers.
class Link extends ChangeNotifier {
  Link(Stream<dynamic> messages, this._send, {Future<void> Function()? close})
    : _close = close {
    _subscription = messages.listen(
      _receive,
      onDone: () {
        closed = true;
        notifyListeners();
      },
    );
  }

  /// Connects to the TUI at [address] ("192.168.1.2:4545", or without the
  /// port for 4545) with the code /phone showed.
  static Future<Link> connect(String address, String code) async {
    final host = address.trim().contains(':')
        ? address.trim()
        : '${address.trim()}:4545';
    final socket = await WebSocket.connect(
      'ws://$host/?code=${Uri.encodeQueryComponent(code.trim())}',
    ).timeout(const Duration(seconds: 8));
    return Link(socket, socket.add, close: socket.close);
  }

  final void Function(String) _send;
  final Future<void> Function()? _close;
  late final StreamSubscription<dynamic> _subscription;

  var sessions = <SessionInfo>[];
  final _entries = <int, List<Map<String, dynamic>>>{};
  var closed = false;

  /// A session's transcript, oldest first.
  List<Map<String, dynamic>> entries(int session) => _entries[session] ?? [];

  SessionInfo? session(int id) => sessions.where((s) => s.id == id).firstOrNull;

  void _receive(dynamic data) {
    if (data is! String) return;
    final Object? message;
    try {
      message = jsonDecode(data);
    } on FormatException {
      return;
    }
    switch (message) {
      case {'type': 'sessions', 'sessions': final List<dynamic> list}:
        sessions = [
          for (final s in list) SessionInfo.fromJson(s as Map<String, dynamic>),
        ];
      case {
        'type': 'entries',
        'session': final int id,
        'from': final int from,
        'entries': final List<dynamic> added,
      }:
        final list = _entries.putIfAbsent(id, () => []);
        if (from < list.length) list.length = from;
        list.addAll(added.cast<Map<String, dynamic>>());
      case {
        'type': 'answered',
        'question': final int id,
        'chosen': final chosen,
      }:
        for (final list in _entries.values) {
          for (final entry in list) {
            if (entry['kind'] == 'question' && entry['id'] == id) {
              entry['chosen'] = chosen;
            }
          }
        }
      default:
        return;
    }
    notifyListeners();
  }

  void prompt(int session, String text) =>
      _send(jsonEncode({'type': 'prompt', 'session': session, 'text': text}));

  void answer(int question, String choice) => _send(
    jsonEncode({'type': 'answer', 'question': question, 'choice': choice}),
  );

  @override
  void dispose() {
    _subscription.cancel();
    _close?.call();
    super.dispose();
  }
}
