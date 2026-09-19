import 'message.dart';

/// In-memory conversation history for one agent session.
final class Session {
  Session({List<Message>? messages}) : _messages = List.of(messages ?? const []);

  final List<Message> _messages;

  List<Message> get messages => List.unmodifiable(_messages);

  void add(Message message) => _messages.add(message);

  void addAll(Iterable<Message> messages) => _messages.addAll(messages);

  void clear() => _messages.clear();

  /// Replace the entire history (used by compact).
  void replaceAll(List<Message> messages) {
    _messages
      ..clear()
      ..addAll(messages);
  }
}
