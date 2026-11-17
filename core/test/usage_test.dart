import 'package:coding_agent_core/src/usage.dart';
import 'package:test/test.dart';

void main() {
  const price = Price(input: 0.25, cachedInput: 0.025, output: 1.5);

  test('prices input, cached input and output per million tokens', () {
    expect(
      price.cost(const Usage(input: 1000000, output: 1000000)),
      closeTo(1.75, 1e-12),
    );
    expect(
      price.cost(const Usage(input: 1000000, cached: 1000000)),
      closeTo(0.025, 1e-12),
    );
  });

  test(
    'bills cached tokens at the input rate when there is no cached rate',
    () {
      const flat = Price(input: 1, output: 2);
      expect(flat.cost(const Usage(input: 10, cached: 4, output: 5)), 20 / 1e6);
    },
  );

  test('the context is what was sent plus the reply', () {
    expect(const Usage(input: 900, cached: 100, output: 50).context, 950);
  });

  test('round-trips through JSON and rejects a price without rates', () {
    final back = Price.fromJson(price.toJson())!;
    expect((back.input, back.cachedInput, back.output), (0.25, 0.025, 1.5));
    expect(Price.fromJson({'input': 1, 'output': 2})!.cachedInput, isNull);
    for (final bad in [
      null,
      3,
      'cheap',
      {'input': 1},
      {'input': 'a', 'output': 1},
    ]) {
      expect(Price.fromJson(bad), isNull, reason: '$bad');
    }
  });
}
