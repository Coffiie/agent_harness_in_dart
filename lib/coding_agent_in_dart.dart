import 'dart:io';

import 'package:google_generative_ai/google_generative_ai.dart';

String divider() {
  return '-' * 20;
}

String input() {
  stdout.write('${divider()}\n');
  stdout.write('You: ');
  final input = stdin.readLineSync() ?? '';
  stdout.write('${divider()}\n');
  return input;
}

void main(List<String> arguments) async {
  final conversation = <String>[];

  final modelName = 'gemini-3.1-flash-lite';
  print(divider());
  print('Chat with $modelName: (press ctrl-c to exit)');
  print(divider());

  while (true) {
    final prompt = input();
    conversation.add("You: $prompt");

    await callModel(modelName, prompt, conversation);
  }
}

Future<void> callModel(
  String modelName,
  String prompt,
  List<String> conversation,
) async {
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
    final content = conversation.map((c) => Content.text(c)).toList();
    final response = await model.generateContent(content);

    final responseWithModelName = "$modelName: ${response.text}";

    // print the response
    print(responseWithModelName);

    //add response to chat history
    conversation.add(responseWithModelName);
  } catch (e) {
    print('Error generating content: $e');
  }
}
