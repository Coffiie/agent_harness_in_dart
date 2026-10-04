import 'messages.dart';
import 'tools.dart';

abstract class ModelProvider {
  Future<Message> generate(List<Message> messages, {List<Tool> tools});

  Future<int> countTokens(List<Message> messages);
}
