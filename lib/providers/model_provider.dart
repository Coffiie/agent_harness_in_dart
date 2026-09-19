import '../core/message.dart';
import '../core/tool.dart';

/// Request sent to a language model for one completion step.
final class CompletionRequest {
  const CompletionRequest({
    required this.messages,
    this.tools = const [],
    this.enableTools = true,
  });

  final List<Message> messages;
  final List<ToolSpec> tools;
  final bool enableTools;
}

/// One model completion result (text and/or tool calls).
final class ModelResponse {
  const ModelResponse({required this.message});

  final Message message;
}

/// Pluggable LLM backend. Implementations own auth, wire format, and schema.
abstract class ModelProvider {
  String get displayName;

  Future<ModelResponse> complete(CompletionRequest request);

  Future<int?> countTokens(List<Message> messages);
}
