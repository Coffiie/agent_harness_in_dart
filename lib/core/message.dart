/// Provider-agnostic chat roles used by the harness.
enum Role { user, assistant, tool }

/// A single piece of content within a [Message].
sealed class ContentPart {
  const ContentPart();
}

/// Plain text content.
final class TextPart extends ContentPart {
  const TextPart(this.text);

  final String text;
}

/// A model-requested tool invocation.
///
/// [providerData] holds opaque provider-specific fields (e.g. Gemini
/// thoughtSignature) that must round-trip with the assistant message.
final class ToolCallPart extends ContentPart {
  const ToolCallPart({
    required this.name,
    required this.args,
    this.id,
    this.providerData,
  });

  final String? id;
  final String name;
  final Map<String, dynamic> args;

  /// Opaque blob preserved by the provider mapper across turns.
  final Object? providerData;
}

/// Result of executing a tool, sent back to the model.
final class ToolResultPart extends ContentPart {
  const ToolResultPart({
    required this.name,
    required this.response,
    this.id,
  });

  final String? id;
  final String name;
  final Map<String, dynamic> response;
}

/// One turn of conversation history.
final class Message {
  const Message({required this.role, required this.parts, this.providerData});

  final Role role;
  final List<ContentPart> parts;

  /// Opaque provider-specific payload for the whole message
  /// (e.g. raw Gemini content map for thoughtSignature).
  final Object? providerData;

  Message copyWith({
    Role? role,
    List<ContentPart>? parts,
    Object? providerData,
  }) {
    return Message(
      role: role ?? this.role,
      parts: parts ?? this.parts,
      providerData: providerData ?? this.providerData,
    );
  }
}
