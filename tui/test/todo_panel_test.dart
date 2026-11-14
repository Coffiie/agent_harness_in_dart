import 'package:coding_agent_core/coding_agent_core.dart';
import 'package:coding_agent_in_dart/src/tui.dart' show visibleTodos, clock;
import 'package:test/test.dart';

void main() {
  test('the panel shows a window that starts at the first open todo', () {
    final plan = Plan(3)
      ..todos.addAll([for (var i = 1; i <= 9; i++) Todo(i, 't$i')]);
    expect(visibleTodos(plan).map((t) => t.id), [1, 2, 3, 4, 5, 6]);

    for (final t in plan.todos.take(5)) {
      t.status = TodoStatus.done;
    }
    expect(visibleTodos(plan).map((t) => t.id), [4, 5, 6, 7, 8, 9]);
  });

  test('times read as minutes and seconds', () {
    expect(clock(const Duration(seconds: 75)), '1:15');
    expect(clock(const Duration(seconds: 9)), '0:09');
  });
}
