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
  // fetch api key from environment variable setup in the terminal
  final apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';

  if (apiKey.isEmpty) {
    print('Error: Please set your GEMINI_API_KEY environment variable.');
    return;
  }

  final conversation = <Content>[];
  final toolResults = <FunctionResponse>[];

  //create the function & tool for read_file
  final readFileFunctionDec = FunctionDeclaration(
    'readFile',
    'Read the contents of a file from a given path',
    Schema.string(description: 'the path of the file', nullable: false),
  );
  final tools = [
    Tool(functionDeclarations: [readFileFunctionDec]),
  ];

  final modelName = 'gemini-3.1-flash-lite';
  print(divider());
  print('Chat with $modelName: (press ctrl-c to exit)');
  print(divider());

  // create a model instance
  final model = GenerativeModel(model: modelName, apiKey: apiKey, tools: tools);

  while (true) {
    final prompt = input();
    conversation.add(Content('user', [TextPart(prompt)]));

    await callModel(model, modelName, conversation, tools, toolResults);
  }
}

Future<void> callModel(
  GenerativeModel model,
  String modelName,
  List<Content> conversation,
  List<Tool> tools,
  List<FunctionResponse> toolResults,
) async {
  try {
    while (true) {
      final response = await model.generateContent(conversation);

      // continue same flow if model did not ask to use a tool
      if (response.text?.isNotEmpty ?? false) {
        // print the response
        print('$modelName: ${response.text}');
        conversation.add(Content('model', [TextPart(response.text!)]));
        break;
      }

      // loop through model's suggested tool calls and call those tools
      for (var function in response.functionCalls) {
        if (function.name == 'readFile') {
          //call readFile
          final response = await readFile(function.args['path'].toString());
          conversation.add(Content('user', [response]));
          continue;
        }
      }
    }
  } catch (e) {
    print('Error generating content: $e');
  }
}

//reads file given a path
Future<FunctionResponse> readFile(String path) async {
  print('Called readFile');

  // Create a reference to the file location
  final file = File(path);

  final toolName = 'readFile';

  try {
    // Read the full file contents asynchronously
    String contents = await file.readAsString();

    return FunctionResponse(toolName, {'content': contents});
  } catch (e) {
    print('Error reading file: $e');
    return FunctionResponse(toolName, {'error': e.toString()});
  }
}
