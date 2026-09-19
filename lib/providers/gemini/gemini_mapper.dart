import '../../core/message.dart';
import '../../core/tool.dart';

/// Maps harness [Message]s to Gemini `contents` / `parts` wire format.
final class GeminiMapper {
  const GeminiMapper();

  List<Map<String, dynamic>> toContents(List<Message> messages) {
    return messages.map(_toContent).toList();
  }

  Map<String, dynamic> _toContent(Message message) {
    // Prefer raw provider blob so thoughtSignature and other fields survive.
    if (message.providerData is Map<String, dynamic>) {
      return Map<String, dynamic>.from(
        message.providerData! as Map<String, dynamic>,
      );
    }

    return {
      'role': _toGeminiRole(message),
      'parts': message.parts.map(_toPart).toList(),
    };
  }

  String _toGeminiRole(Message message) {
    return switch (message.role) {
      Role.user || Role.tool => 'user',
      Role.assistant => 'model',
    };
  }

  Map<String, dynamic> _toPart(ContentPart part) {
    return switch (part) {
      TextPart(:final text) => {'text': text},
      ToolCallPart(:final name, :final args, :final providerData) =>
        providerData is Map<String, dynamic>
            ? Map<String, dynamic>.from(providerData)
            : {
                'functionCall': {'name': name, 'args': args},
              },
      ToolResultPart(:final name, :final response) => {
        'functionResponse': {'name': name, 'response': response},
      },
    };
  }

  /// Convert a Gemini `content` object into a harness [Message].
  Message fromModelContent(Map<String, dynamic> modelContent) {
    final parts = (modelContent['parts'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    final contentParts = <ContentPart>[];
    for (final part in parts) {
      if (part.containsKey('text')) {
        final text = part['text'] as String? ?? '';
        if (text.isNotEmpty) {
          contentParts.add(TextPart(text));
        }
      } else if (part.containsKey('functionCall')) {
        final fc = part['functionCall'] as Map<String, dynamic>;
        contentParts.add(
          ToolCallPart(
            name: fc['name'] as String,
            args: (fc['args'] as Map<String, dynamic>?) ?? {},
            // Keep the whole part so thoughtSignature on the part is preserved
            // when we fall back; full message uses providerData below.
            providerData: part,
          ),
        );
      }
    }

    return Message(
      role: Role.assistant,
      parts: contentParts,
      // Preserve the raw Gemini content map for thoughtSignature round-trip.
      providerData: modelContent,
    );
  }

  List<Map<String, dynamic>> toFunctionDeclarations(List<ToolSpec> tools) {
    if (tools.isEmpty) return const [];

    return [
      {
        'functionDeclarations': tools.map(_toolToDeclaration).toList(),
      },
    ];
  }

  Map<String, dynamic> _toolToDeclaration(ToolSpec tool) {
    final properties = <String, dynamic>{};
    final required = <String>[];

    for (final param in tool.parameters) {
      properties[param.name] = {
        'type': param.type,
        'description': param.description,
      };
      if (param.required) {
        required.add(param.name);
      }
    }

    final parameters = <String, dynamic>{
      'type': 'OBJECT',
      'properties': properties,
    };
    if (required.isNotEmpty) {
      parameters['required'] = required;
    }

    return {
      'name': tool.name,
      'description': tool.description,
      'parameters': parameters,
    };
  }
}
