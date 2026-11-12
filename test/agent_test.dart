import 'package:coding_agent_in_dart/src/agent.dart';
import 'package:coding_agent_in_dart/src/events.dart';
import 'package:coding_agent_in_dart/src/messages.dart';
import 'package:coding_agent_in_dart/src/model_provider.dart';
import 'package:coding_agent_in_dart/src/tools.dart';
import 'package:coding_agent_in_dart/src/usage.dart';
import 'package:test/test.dart';

class FakeProvider implements ModelProvider {
  FakeProvider(this.replies);

  final List<Message> replies;
  final requests = <(List<Message>, List<Tool>)>[];
  final systems = <String?>[];

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async {
    requests.add((List.of(messages), tools));
    systems.add(system);
    if (replies.isEmpty) throw Exception('no reply');
    return replies.removeAt(0);
  }

  @override
  Future<int> countTokens(List<Message> messages) async => messages.length;
}

Message say(String text) => Message(Role.assistant, [TextPart(text)]);

Message call(String name, Map<String, dynamic> args) =>
    Message(Role.assistant, [ToolCall(name, args)]);

final echo = Tool(
  name: 'echo',
  description: 'Echo the text',
  parameters: {},
  label: (args) => 'Echo(${args['text']})',
  run: (args) async => {'echo': args['text']},
);

void main() {
  test('sends the prompt and yields the reply text', () async {
    final provider = FakeProvider([say('hi')]);

    final events = await Agent(provider, [echo]).send('hello').toList();

    expect(events, [isA<AssistantText>().having((e) => e.text, 'text', 'hi')]);
    final (messages, tools) = provider.requests.single;
    expect(messages.single.role, Role.user);
    expect((messages.single.parts.single as TextPart).text, 'hello');
    expect(tools, [echo]);
  });

  test('runs the tools the model calls until it stops calling', () async {
    final provider = FakeProvider([
      call('echo', {'text': 'ping'}),
      say('done'),
    ]);

    final events = await Agent(provider, [echo]).send('go').toList();

    expect(events, [
      isA<ToolStarted>().having((e) => e.label, 'label', 'Echo(ping)'),
      isA<AssistantText>().having((e) => e.text, 'text', 'done'),
    ]);
    final (messages, _) = provider.requests.last;
    expect(messages.map((m) => m.role), [Role.user, Role.assistant, Role.user]);
    final result = messages.last.parts.single as ToolResult;
    expect(result.name, 'echo');
    expect(result.output, {'echo': 'ping'});
  });

  test('answers a call to an unknown tool with an error', () async {
    final provider = FakeProvider([call('nope', {}), say('ok')]);

    final events = await Agent(provider, [echo]).send('go').toList();

    expect(events.single, isA<AssistantText>());
    final (messages, _) = provider.requests.last;
    final result = messages.last.parts.single as ToolResult;
    expect(result.output, {'error': 'Unknown function: nope'});
  });

  test('yields an error when the provider fails', () async {
    final events = await Agent(FakeProvider([]), []).send('hello').toList();

    expect(events, [
      isA<AgentError>().having(
        (e) => e.message,
        'message',
        'Exception: no reply',
      ),
    ]);
  });

  test('compact replaces the conversation with a summary', () async {
    final provider = FakeProvider([
      say('hi'),
      say('[CompactedSummaryFromModel] we said hi'),
      say('ok'),
    ]);
    final agent = Agent(provider, [echo]);
    await agent.send('hello').drain<void>();

    final events = await agent.compact().toList();

    expect(events, [
      isA<CompactionStarted>(),
      isA<Compacted>()
          .having((e) => e.before, 'before', 2)
          .having((e) => e.after, 'after', 1),
    ]);
    final (summaryRequest, summaryTools) = provider.requests[1];
    expect(summaryRequest, hasLength(3));
    expect(
      (summaryRequest.last.parts.single as TextPart).text,
      startsWith('Please summarize the entire conversation'),
    );
    expect(summaryTools, isEmpty);

    await agent.send('next').drain<void>();
    final (messages, _) = provider.requests.last;
    expect(messages.map((m) => m.role), [Role.assistant, Role.user]);
    expect(
      (messages.first.parts.single as TextPart).text,
      '[CompactedSummaryFromModel] we said hi',
    );
  });

  test('compact keeps the conversation when there is no summary', () async {
    final provider = FakeProvider([say('hi'), say(''), say('ok')]);
    final agent = Agent(provider, [echo]);
    await agent.send('hello').drain<void>();

    final events = await agent.compact().toList();

    expect(events, [
      isA<CompactionStarted>(),
      isA<AgentError>().having((e) => e.message, 'message', 'while compacting'),
    ]);
    await agent.send('next').drain<void>();
    final (messages, _) = provider.requests.last;
    expect(messages, hasLength(3));
  });

  test('reports the usage of every call, compaction included', () async {
    const first = Usage(input: 100, output: 10);
    const second = Usage(input: 130, output: 20);
    const summary = Usage(input: 160, output: 5);
    final provider = FakeProvider([
      Message(Role.assistant, [
        const ToolCall('echo', {'text': 'ping'}),
      ], usage: first),
      Message(Role.assistant, [const TextPart('done')], usage: second),
      Message(Role.assistant, [const TextPart('summary')], usage: summary),
    ]);
    final agent = Agent(provider, [echo]);

    final sent = await agent.send('go').toList();
    final compacted = await agent.compact().toList();

    expect(sent.whereType<UsageReported>().map((e) => e.usage), [
      first,
      second,
    ]);
    expect(compacted.whereType<UsageReported>().map((e) => e.usage), [summary]);
  });

  test('sends its system prompt with every request', () async {
    final provider = FakeProvider([say('hi'), say('summary')]);
    final agent = Agent(provider, [echo], system: 'be brief');

    await agent.send('hello').drain<void>();
    await agent.compact().drain<void>();

    expect(provider.systems, ['be brief', 'be brief']);
  });

  test('sends no system prompt unless it has one', () async {
    final provider = FakeProvider([say('hi')]);

    await Agent(provider, [echo]).send('hello').drain<void>();

    expect(provider.systems, [null]);
  });
}
