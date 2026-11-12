import 'diff.dart';
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

class AgentError extends AgentEvent {
  const AgentError(this.message);

  final String message;
}
