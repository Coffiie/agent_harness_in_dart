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

/// The provider can't take the request now: it's over its rate limit
/// (429), or too busy (5xx). It waits [retryAfter] before the next
/// request, whichever session sends it.
class TryLater extends ProviderError {
  const TryLater(super.status, super.message, {this.retryAfter});

  final Duration? retryAfter;
}

/// The provider said to slow down.
class RateLimited extends TryLater {
  const RateLimited(String message, {Duration? retryAfter})
    : super(429, message, retryAfter: retryAfter);
}
