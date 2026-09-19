import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/message.dart';
import '../model_provider.dart';
import 'gemini_mapper.dart';

/// Google Gemini Generative Language API provider.
final class GeminiProvider implements ModelProvider {
  GeminiProvider({
    this.model = 'gemini-3.1-flash-lite',
    this.apiKey,
    this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta/models',
    http.Client? httpClient,
    GeminiMapper mapper = const GeminiMapper(),
  }) : _http = httpClient ?? http.Client(),
       _mapper = mapper,
       _ownsClient = httpClient == null;

  final String model;
  final String? apiKey;
  final String baseUrl;
  final http.Client _http;
  final GeminiMapper _mapper;
  final bool _ownsClient;

  @override
  String get displayName => model;

  String _resolveApiKey() {
    final key = apiKey ?? Platform.environment['GEMINI_API_KEY'] ?? '';
    if (key.isEmpty) {
      throw StateError(
        'Please set your GEMINI_API_KEY environment variable.',
      );
    }
    return key;
  }

  @override
  Future<ModelResponse> complete(CompletionRequest request) async {
    final key = _resolveApiKey();
    final uri = Uri.parse('$baseUrl/$model:generateContent');

    final bodyMap = <String, dynamic>{
      'contents': _mapper.toContents(request.messages),
    };
    if (request.enableTools && request.tools.isNotEmpty) {
      bodyMap['tools'] = _mapper.toFunctionDeclarations(request.tools);
    }

    final response = await _http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': key,
      },
      body: jsonEncode(bodyMap),
    );

    if (response.statusCode != 200) {
      throw Exception('${response.statusCode}: ${response.body}');
    }

    final responseBody = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = responseBody['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw StateError('Error: receiving candidates');
    }

    final modelContent =
        (candidates.first as Map<String, dynamic>)['content']
            as Map<String, dynamic>?;
    if (modelContent == null) {
      throw StateError('Error: model content is null');
    }

    return ModelResponse(message: _mapper.fromModelContent(modelContent));
  }

  @override
  Future<int?> countTokens(List<Message> messages) async {
    final key = _resolveApiKey();
    final uri = Uri.parse('$baseUrl/$model:countTokens');
    final body = jsonEncode({'contents': _mapper.toContents(messages)});

    final response = await _http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': key,
      },
      body: body,
    );

    if (response.statusCode != 200) {
      return null;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['totalTokens'] as int?;
  }

  void close() {
    if (_ownsClient) {
      _http.close();
    }
  }
}
