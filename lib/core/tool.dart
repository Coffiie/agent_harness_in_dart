/// JSON-schema-like parameter description for a tool.
final class ToolParameter {
  const ToolParameter({
    required this.name,
    required this.type,
    required this.description,
    this.required = false,
  });

  final String name;

  /// Uppercase JSON Schema type used by providers (STRING, OBJECT, …).
  final String type;
  final String description;
  final bool required;
}

/// Declarative tool metadata the model can call.
final class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    this.parameters = const [],
  });

  final String name;
  final String description;
  final List<ToolParameter> parameters;
}

typedef ToolHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> args);

/// Named tool: schema for the model + local handler.
final class Tool {
  const Tool({required this.spec, required this.handler});

  final ToolSpec spec;
  final ToolHandler handler;
}

/// Registry of tools available to an [Agent].
final class ToolRegistry {
  ToolRegistry([Iterable<Tool> tools = const []]) {
    for (final tool in tools) {
      register(tool);
    }
  }

  final Map<String, Tool> _tools = {};

  void register(Tool tool) {
    _tools[tool.spec.name] = tool;
  }

  List<ToolSpec> get specs =>
      _tools.values.map((t) => t.spec).toList(growable: false);

  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    final tool = _tools[name];
    if (tool == null) {
      return {'error': 'Unknown function: $name'};
    }
    return tool.handler(args);
  }
}
