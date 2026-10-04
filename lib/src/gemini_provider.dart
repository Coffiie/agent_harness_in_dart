import 'dart:convert';

import 'package:http/http.dart' as http;

import 'messages.dart';
import 'model_provider.dart';
import 'tools.dart';

const _baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models';

class GeminiProvider implements ModelProvider {
  GeminiProvider(
    this._apiKey, {
    this.model = 'gemini-3.1-flash-lite',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String _apiKey;
  final http.Client _client;
  final String model;

  @override
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
  }) async {
    final response = await _post('generateContent', {
      'contents': messages.map(_toContent).toList(),
      if (tools.isNotEmpty)
        'tools': [
          {'functionDeclarations': tools.map(_toDeclaration).toList()},
        ],
    });

    final candidates = response['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('receiving candidates');
    }

    final content = candidates.first['content'] as Map<String, dynamic>?;
    if (content == null) {
      throw Exception('model content is null');
    }

    return Message(Role.assistant, [
      for (final part in content['parts'] as List<dynamic>)
        if (part['functionCall'] case final Map<String, dynamic> call)
          ToolCall(
            call['name'] as String,
            call['args'] as Map<String, dynamic>? ?? {},
          )
        else if (part['text'] case final String text)
          TextPart(text),
    ], raw: content);
  }

  @override
  Future<int> countTokens(List<Message> messages) async {
    final response = await _post('countTokens', {
      'contents': messages.map(_toContent).toList(),
    });
    return response['totalTokens'] as int;
  }

  Map<String, dynamic> _toContent(Message message) {
    // this is what preserves thoughtSignature
    if (message.raw case final Map<String, dynamic> raw) return raw;

    return {
      'role': message.role == Role.user ? 'user' : 'model',
      'parts': [
        for (final part in message.parts)
          switch (part) {
            TextPart(:final text) => {'text': text},
            ToolCall(:final name, :final args) => {
              'functionCall': {'name': name, 'args': args},
            },
            ToolResult(:final name, :final output) => {
              'functionResponse': {'name': name, 'response': output},
            },
          },
      ],
    };
  }

  Map<String, dynamic> _toDeclaration(Tool tool) => {
    'name': tool.name,
    'description': tool.description,
    'parameters': _upperCaseTypes(tool.parameters),
  };

  dynamic _upperCaseTypes(dynamic schema) => schema is Map
      ? schema.map(
          (key, value) => MapEntry(
            key,
            key == 'type' ? value.toUpperCase() : _upperCaseTypes(value),
          ),
        )
      : schema;

  Future<Map<String, dynamic>> _post(
    String method,
    Map<String, dynamic> body,
  ) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/$model:$method'),
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': _apiKey},
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('${response.statusCode}: ${response.body}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
