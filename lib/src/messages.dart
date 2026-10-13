enum Role { user, assistant }

sealed class Part {
  const Part();
}

class TextPart extends Part {
  const TextPart(this.text);

  final String text;
}

class ToolCall extends Part {
  const ToolCall(this.name, this.args);

  final String name;
  final Map<String, dynamic> args;
}

class ToolResult extends Part {
  const ToolResult(this.name, this.output);

  final String name;
  final Map<String, dynamic> output;
}

class Message {
  const Message(this.role, this.parts, {this.raw});

  final Role role;
  final List<Part> parts;
  final Object? raw;
}
