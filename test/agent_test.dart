import 'package:coding_agent_in_dart/coding_agent_in_dart.dart';
import 'package:test/test.dart';

/// Scripted [ModelProvider] for harness tests.
final class FakeModelProvider implements ModelProvider {
  FakeModelProvider(this._responses);

  final List<ModelResponse> _responses;
  int _index = 0;
  final List<CompletionRequest> requests = [];

  @override
  String get displayName => 'fake-model';

  @override
  Future<ModelResponse> complete(CompletionRequest request) async {
    requests.add(request);
    if (_index >= _responses.length) {
      throw StateError('No more fake responses');
    }
    return _responses[_index++];
  }

  @override
  Future<int?> countTokens(List<Message> messages) async => messages.length;
}

void main() {
  group('ToolRegistry', () {
    test('dispatches known tools', () async {
      final registry = ToolRegistry([
        Tool(
          spec: const ToolSpec(name: 'echo', description: 'echo args'),
          handler: (args) async => {'echo': args['value']},
        ),
      ]);

      final result = await registry.execute('echo', {'value': 'hi'});
      expect(result, {'echo': 'hi'});
    });

    test('returns error for unknown tools', () async {
      final registry = ToolRegistry();
      final result = await registry.execute('missing', {});
      expect(result['error'], contains('Unknown function'));
    });
  });

  group('Agent', () {
    test('text-only turn emits AssistantText and TurnComplete', () async {
      final provider = FakeModelProvider([
        ModelResponse(
          message: Message(
            role: Role.assistant,
            parts: [const TextPart('hello')],
          ),
        ),
      ]);
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry(),
      );

      final events = await agent.runTurn('hi').toList();

      expect(events, [
        isA<AssistantText>().having((e) => e.text, 'text', 'hello'),
        isA<TurnComplete>(),
      ]);
      expect(agent.session.messages, hasLength(2));
      expect(agent.session.messages.first.role, Role.user);
      expect(agent.session.messages.last.role, Role.assistant);
    });

    test('tool-call then text runs tool and completes', () async {
      final provider = FakeModelProvider([
        ModelResponse(
          message: Message(
            role: Role.assistant,
            parts: [
              ToolCallPart(name: 'echo', args: {'value': 'x'}),
            ],
          ),
        ),
        ModelResponse(
          message: Message(
            role: Role.assistant,
            parts: [const TextPart('done')],
          ),
        ),
      ]);

      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          Tool(
            spec: const ToolSpec(name: 'echo', description: 'echo'),
            handler: (args) async => {'echo': args['value']},
          ),
        ]),
      );

      final events = await agent.runTurn('use tool').toList();

      expect(events[0], isA<ToolStarted>());
      expect(events[1], isA<ToolFinished>());
      expect(
        (events[1] as ToolFinished).result,
        {'echo': 'x'},
      );
      expect(events[2], isA<AssistantText>());
      expect(events[3], isA<TurnComplete>());

      // user, assistant(tool call), tool result, assistant(text)
      expect(agent.session.messages, hasLength(4));
      expect(agent.session.messages[2].role, Role.tool);
    });

    test('compact replaces session with summary', () async {
      final provider = FakeModelProvider([
        ModelResponse(
          message: Message(
            role: Role.assistant,
            parts: [
              const TextPart('[CompactedSummaryFromModel]\n- point one'),
            ],
          ),
        ),
      ]);

      final session = Session(
        messages: [
          Message(role: Role.user, parts: [const TextPart('old')]),
          Message(role: Role.assistant, parts: [const TextPart('reply')]),
        ],
      );

      final agent = Agent(
        provider: provider,
        tools: ToolRegistry(),
        session: session,
      );

      final events = await agent.compact().toList();

      expect(events.first, isA<CompactProgress>());
      expect(events.last, isA<CompactComplete>());
      expect(agent.session.messages, hasLength(1));
      expect(agent.session.messages.single.role, Role.assistant);
      final text =
          (agent.session.messages.single.parts.single as TextPart).text;
      expect(text, contains('[CompactedSummaryFromModel]'));
      expect(provider.requests.single.enableTools, isFalse);
    });

    test('stops after max tool iterations', () async {
      final endless = List.generate(
        25,
        (_) => ModelResponse(
          message: Message(
            role: Role.assistant,
            parts: [
              ToolCallPart(name: 'echo', args: {'value': 'loop'}),
            ],
          ),
        ),
      );

      final agent = Agent(
        provider: FakeModelProvider(endless),
        tools: ToolRegistry([
          Tool(
            spec: const ToolSpec(name: 'echo', description: 'echo'),
            handler: (args) async => args,
          ),
        ]),
        maxToolIterations: 3,
      );

      final events = await agent.runTurn('loop').toList();
      expect(events.last, isA<AgentError>());
      expect(
        (events.last as AgentError).message,
        contains('maximum tool iterations'),
      );
    });
  });

  group('GeminiMapper', () {
    const mapper = GeminiMapper();

    test('maps tool specs to functionDeclarations', () {
      final tools = mapper.toFunctionDeclarations([
        const ToolSpec(
          name: 'readFile',
          description: 'Read a file',
          parameters: [
            ToolParameter(
              name: 'path',
              type: 'STRING',
              description: 'path',
              required: true,
            ),
          ],
        ),
      ]);

      expect(tools, hasLength(1));
      final decls = tools.first['functionDeclarations'] as List;
      expect(decls.first['name'], 'readFile');
      expect(decls.first['parameters']['required'], ['path']);
    });

    test('preserves providerData on round-trip contents', () {
      final raw = {
        'role': 'model',
        'parts': [
          {'text': 'hi', 'thoughtSignature': 'sig'},
        ],
      };
      final message = Message(
        role: Role.assistant,
        parts: [const TextPart('hi')],
        providerData: raw,
      );

      final contents = mapper.toContents([message]);
      expect(contents.single, raw);
    });
  });
}
