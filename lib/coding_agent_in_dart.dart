import 'dart:io';

import 'package:google_generative_ai/google_generative_ai.dart';

void main(List<String> arguments) async {
  // fetch api key from environment variable setup in the terminal
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return;
  }

  // create a model instance
  final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: apiKey);

  try {
    // create a content instance
    final content = [Content.text('What is the capital of France?')];
    final response = await model.generateContent(content);

    // print the response
    print(response.text);
  } catch (e) {
    print('Error generating content: $e');
  }
}
