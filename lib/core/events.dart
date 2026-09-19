/// Events emitted by the agent harness for UI layers to render.
sealed class AgentEvent {
  const AgentEvent();
}

/// Assistant produced visible text.
final class AssistantText extends AgentEvent {
  const AssistantText(this.text);

  final String text;
}

/// A tool invocation is about to run.
final class ToolStarted extends AgentEvent {
  const ToolStarted({required this.name, required this.args});

  final String name;
  final Map<String, dynamic> args;
}

/// A tool invocation finished.
final class ToolFinished extends AgentEvent {
  const ToolFinished({
    required this.name,
    required this.args,
    required this.result,
  });

  final String name;
  final Map<String, dynamic> args;
  final Map<String, dynamic> result;
}

/// The current user turn completed (no more tool calls).
final class TurnComplete extends AgentEvent {
  const TurnComplete();
}

/// Compact summarization is in progress.
final class CompactProgress extends AgentEvent {
  const CompactProgress();
}

/// Compact finished; [beforeTokens]/[afterTokens] may be -1 if unknown.
final class CompactComplete extends AgentEvent {
  const CompactComplete({
    required this.beforeTokens,
    required this.afterTokens,
  });

  final int beforeTokens;
  final int afterTokens;
}

/// A recoverable or terminal error during a turn.
final class AgentError extends AgentEvent {
  const AgentError(this.message);

  final String message;
}
