import 'dart:io';

import 'package:google_generative_ai/google_generative_ai.dart';

String input() {
  return stdin.readLineSync() ?? '';
}

void main(List<String> arguments) async {
  final modelName = 'gemini-2.5-flash';

  print('Chat with $modelName:');
  final prompt = input();

  callModel(modelName, prompt);
}

void callModel(String modelName, String prompt) async {
  // fetch api key from environment variable setup in the terminal
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return;
  }

  // create a model instance
  final model = GenerativeModel(model: modelName, apiKey: apiKey);

  try {
    // create a content instance
    final content = [Content.text(prompt)];
    final response = await model.generateContent(content);

    // print the response
    print("$modelName: ${response.text}");
  } catch (e) {
    print('Error generating content: $e');
  }
}
