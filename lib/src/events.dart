sealed class AgentEvent {
  const AgentEvent();
}

class AssistantText extends AgentEvent {
  const AssistantText(this.text);

  final String text;
}

class ToolStarted extends AgentEvent {
  const ToolStarted(this.label);

  final String label;
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
