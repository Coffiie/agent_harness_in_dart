import 'diff.dart';
import 'question.dart';
import 'usage.dart';

sealed class AgentEvent {
  const AgentEvent();
}

class AssistantText extends AgentEvent {
  const AssistantText(this.text);

  final String text;
}

class ToolStarted extends AgentEvent {
  const ToolStarted(this.label, {this.diff = const []});

  final String label;
  final List<DiffLine> diff;
}

/// What a tool said back, when the user should see it: a command's
/// output, or why the tool failed.
class ToolFinished extends AgentEvent {
  const ToolFinished(this.output, {this.failed = false});

  final String output;
  final bool failed;
}

/// The model asked the user something, and the turn waits until
/// [question] is answered.
class Asked extends AgentEvent {
  const Asked(this.question);

  final Question question;
}

/// The tokens one model call used. Comes after every call that reports
/// them, compaction included.
class UsageReported extends AgentEvent {
  const UsageReported(this.usage);

  final Usage usage;
}

class CompactionStarted extends AgentEvent {
  const CompactionStarted();
}

class Compacted extends AgentEvent {
  const Compacted(this.before, this.after);

  final int before;
  final int after;
}

/// The provider's rate limit, or a busy provider, stopped a request. The
/// agent waits [wait], then tries it again.
class RetryWait extends AgentEvent {
  const RetryWait(this.wait, this.message, {this.status = 429});

  final Duration wait;
  final String message;

  /// 429 for the rate limit; 5xx when the provider was busy.
  final int status;
}

/// What the TUI, the phone and the CLI say about a [RetryWait].
String retryNote(RetryWait retry) => retry.status == 429
    ? "Gemini's rate limit: waiting ${retry.wait.inSeconds}s, then trying "
          'again'
    : 'Gemini is busy (${retry.status}): waiting ${retry.wait.inSeconds}s, '
          'then trying again';

class AgentError extends AgentEvent {
  const AgentError(this.message);

  final String message;
}
