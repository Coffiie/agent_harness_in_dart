import 'messages.dart';
import 'tools.dart';

abstract class ModelProvider {
  Future<Message> generate(
    List<Message> messages, {
    List<Tool> tools,
    String? system,
  });

  Future<int> countTokens(List<Message> messages);
}
