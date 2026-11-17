import 'package:coding_agent_core/src/agent.dart';
import 'package:coding_agent_core/src/events.dart';
import 'package:coding_agent_core/src/messages.dart';
import 'package:coding_agent_core/src/model_provider.dart';
import 'package:coding_agent_core/src/question.dart';
import 'package:coding_agent_core/src/tools.dart';
import 'package:coding_agent_core/src/usage.dart';
import 'package:test/test.dart';

class FakeProvider implements ModelProvider {
  @override
  String get name => 'Gemini';

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

  test("yields what a tool said back when it's for the user", () async {
    Tool says(String name, Map<String, dynamic> result) => Tool(
      name: name,
      description: name,
      parameters: {},
      label: (_) => name,
      run: (_) async => result,
    );
    final provider = FakeProvider([
      call('passes', {}),
      call('quiet', {}),
      call('quietFail', {}),
      call('fails', {}),
      call('missing', {}),
      call('refused', {}),
      call('echo', {'text': 'ping'}),
      say('ok'),
    ]);

    final events = await Agent(provider, [
      says('passes', {'exitCode': 0, 'output': 'All tests passed!'}),
      says('quiet', {'exitCode': 0, 'output': ''}),
      says('quietFail', {'exitCode': 2, 'output': '\n'}),
      says('fails', {'exitCode': 1, 'output': 'Some tests failed.'}),
      says('missing', {'error': 'No such file or directory'}),
      says('refused', {'status': 'error', 'message': 'Read-only file system'}),
      echo,
    ]).send('go').toList();

    expect(events.whereType<ToolFinished>().map((e) => (e.output, e.failed)), [
      ('All tests passed!', false),
      ('exit code 2', true),
      ('Some tests failed.', true),
      ('No such file or directory', true),
      ('Read-only file system', true),
    ]);
    // echo's result is only for the model
    expect(events[events.length - 2], isA<ToolStarted>());
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

  test('waits for the answer to askUser and sends it back', () async {
    final provider = FakeProvider([
      call('askUser', {
        'question': 'Which?',
        'options': ['a', 'b'],
      }),
      say('ok'),
    ]);
    final events = <AgentEvent>[];

    final done = Agent(provider, [askUserTool]).send('go').forEach((event) {
      events.add(event);
      if (event is Asked) {
        expect(event.question.options, ['a', 'b']);
        // the model must not hear back until someone answers
        expect(provider.requests, hasLength(1));
        event.question.reply('b');
      }
    });
    await done;

    expect(events.whereType<Asked>(), hasLength(1));
    final result = provider.requests.last.$1.last.parts.single as ToolResult;
    expect(result.output, {'answer': 'b'});
  });

  test('askUser with no options is an error, not a question', () async {
    final provider = FakeProvider([
      call('askUser', {'question': 'Which?'}),
      say('ok'),
    ]);

    final events = await Agent(provider, [askUserTool]).send('go').toList();

    expect(events.whereType<Asked>(), isEmpty);
    final result = provider.requests.last.$1.last.parts.single as ToolResult;
    expect(result.output, contains('error'));
  });

  test('puts notes in front of the next prompt, once', () async {
    final provider = FakeProvider([say('ok'), say('ok')]);
    final agent = Agent(provider, [echo])..note('[undone]');

    await agent.send('next').toList();
    await agent.send('again').toList();

    List<String> texts(Message m) => [
      for (final p in m.parts) (p as TextPart).text,
    ];
    expect(texts(provider.requests[0].$1.last), ['[undone]', 'next']);
    expect(texts(provider.requests[1].$1.last), ['again']);
  });

  test('a note waiting at /compact goes into the summary request', () async {
    final provider = FakeProvider([say('hi'), say('summary')]);
    final agent = Agent(provider, [echo]);

    await agent.send('hello').toList();
    agent.note('[undone]');
    await agent.compact().toList();

    final last = provider.requests[1].$1.last;
    expect((last.parts.first as TextPart).text, '[undone]');
    expect(last.parts, hasLength(2));
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

  test('starts from a conversation it is given', () async {
    final provider = FakeProvider([say('Lyon')]);
    final agent = Agent(
      provider,
      [],
      conversation: [
        Message(Role.user, [const TextPart('capital of France?')]),
        say('Paris'),
      ],
    );

    await agent.send('and the second city?').toList();

    expect(provider.requests.single.$1, hasLength(3));
    expect(agent.conversation, hasLength(4));
  });

  group('handoff', () {
    Agent chatted(FakeProvider provider) => Agent(
      provider,
      [],
      conversation: [
        Message(Role.user, [const TextPart('capital of France?')]),
        say('Paris'),
      ],
    );

    test(
      'returns no summary when the model says the prompt needs none',
      () async {
        final provider = FakeProvider([say('NONE')]);
        final agent = chatted(provider);

        final handoff = await agent.handoff('write a haiku');

        expect(handoff.summary, isNull);
        final asked = provider.requests.single.$1;
        expect(asked, hasLength(3));
        expect(
          (asked.last.parts.single as TextPart).text,
          endsWith('write a haiku'),
        );
        expect(agent.conversation, hasLength(2)); // left as it was
      },
    );

    test('returns the summary and what the call cost', () async {
      final provider = FakeProvider([
        Message(Role.assistant, [
          const TextPart('[CompactedSummaryFromModel] - Paris is the capital'),
        ], usage: const Usage(input: 10, output: 5)),
      ]);

      final handoff = await chatted(provider).handoff('and the second city?');

      expect(handoff.summary, contains('Paris is the capital'));
      expect(handoff.usage?.output, 5);
    });

    test('makes no call when there is no chat yet', () async {
      final provider = FakeProvider([]);

      final handoff = await Agent(provider, []).handoff('hello');

      expect(handoff.summary, isNull);
      expect(provider.requests, isEmpty);
    });
  });

  group('rate limit', () {
    test('waits and tries the same request again', () async {
      var calls = 0;
      final provider = ScriptedFailures([
        const RateLimited('quota', retryAfter: Duration(seconds: 34)),
        const RateLimited('quota'),
      ], then: say('hi'));

      final events = await Agent(provider, [echo]).send('hello').toList();
      calls = provider.calls;

      expect(events, [
        isA<RetryWait>()
            .having((e) => e.wait, 'wait', const Duration(seconds: 34))
            .having((e) => e.message, 'message', 'quota'),
        isA<RetryWait>().having(
          (e) => e.wait,
          'wait',
          const Duration(seconds: 10),
        ),
        isA<AssistantText>().having((e) => e.text, 'text', 'hi'),
      ]);
      expect(calls, 3);
      // the same chat each time: the prompt, then the reply
      expect(provider.sizes, [1, 1, 1]);
    });

    test('waits out a busy Gemini the same way', () async {
      final provider = ScriptedFailures([
        const TryLater(
          503,
          'This model is currently experiencing high demand.',
          retryAfter: Duration(seconds: 5),
        ),
      ], then: say('hi'));

      final events = await Agent(provider, [echo]).send('hello').toList();

      final retry = events.first as RetryWait;
      expect(
        retryNote(retry),
        'Gemini is busy (503): waiting 5s, then trying again',
      );
      expect(events.last, isA<AssistantText>());
    });

    test('gives up after ${Agent.mostRetries} tries in a row', () async {
      final provider = ScriptedFailures([
        for (var i = 0; i <= Agent.mostRetries; i++) const RateLimited('quota'),
      ], then: say('never'));

      final events = await Agent(provider, [echo]).send('hello').toList();

      expect(events.whereType<RetryWait>(), hasLength(Agent.mostRetries));
      expect(
        (events.last as AgentError).message,
        "Gemini's rate limit, after trying ${Agent.mostRetries} times: quota",
      );
    });
  });
}

/// Throws [failures] one call at a time, then answers [then].
class ScriptedFailures implements ModelProvider {
  @override
  String get name => 'Gemini';

  ScriptedFailures(this.failures, {required this.then});

  final List<Exception> failures;
  final Message then;
  var calls = 0;
  final sizes = <int>[];

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? system,
  }) async {
    calls++;
    sizes.add(messages.length);
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return then;
  }

  @override
  Future<int> countTokens(List<Message> messages) async => messages.length;
}
