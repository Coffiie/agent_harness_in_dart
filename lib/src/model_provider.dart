import 'messages.dart';
import 'tools.dart';

abstract class ModelProvider {
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools,
    String? system,
  });

  Future<int> countTokens(List<Message> messages);
}

/// The provider answered with an error. [message] is the part a person can
/// read, not the whole body.
class ProviderError implements Exception {
  const ProviderError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => '$status: $message';
}

/// The provider said to slow down, and asked to wait [retryAfter] when it
/// said how long. Until then, every request to it waits, whichever session
/// sends it.
class RateLimited extends ProviderError {
  const RateLimited(String message, {this.retryAfter}) : super(429, message);

  final Duration? retryAfter;
}
