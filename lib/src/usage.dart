/// The tokens one model call used, as the provider reported them.
class Usage {
  const Usage({this.input = 0, this.cached = 0, this.output = 0});

  /// Everything the model read: the system prompt, the tools and the whole
  /// chat so far. [cached] of these were billed at the cached rate.
  final int input;

  /// How many of the [input] tokens came from the provider's cache.
  final int cached;

  /// What the model wrote, thinking included.
  final int output;

  /// The chat's size after this call: what was sent, plus the reply.
  int get context => input + output;
}

/// What a model costs, in dollars per million tokens.
class Price {
  const Price({required this.input, this.cachedInput, required this.output});

  final double input;

  /// The rate for cached input tokens. Without one, they cost [input].
  final double? cachedInput;
  final double output;

  /// What [usage] cost, in dollars.
  double cost(Usage usage) =>
      ((usage.input - usage.cached) * input +
          usage.cached * (cachedInput ?? input) +
          usage.output * output) /
      1e6;

  Map<String, dynamic> toJson() => {
    'input': input,
    if (cachedInput != null) 'cachedInput': cachedInput,
    'output': output,
  };

  /// Reads a price saved by [toJson]. Returns null unless both rates are
  /// numbers.
  static Price? fromJson(Object? json) {
    if (json is! Map) return null;
    final (input, cached, output) = (
      json['input'],
      json['cachedInput'],
      json['output'],
    );
    if (input is! num || output is! num) return null;
    return Price(
      input: input.toDouble(),
      cachedInput: cached is num ? cached.toDouble() : null,
      output: output.toDouble(),
    );
  }
}
