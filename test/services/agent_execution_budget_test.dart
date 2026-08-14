import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_execution_budget.dart';

void main() {
  group('AgentExecutionBudget', () {
    test(
      'stops before a model request once its iteration limit is exhausted',
      () {
        final budget = AgentExecutionBudget(maxModelRequests: 1);
        final now = DateTime(2026);

        expect(budget.consumeModelRequest(now), isNull);
        expect(
          budget.consumeModelRequest(now)?.limit,
          AgentBudgetLimit.modelRequests,
        );
      },
    );

    test('does not consume a shell call when its limit has been reached', () {
      final budget = AgentExecutionBudget(maxShellCalls: 1);
      final now = DateTime(2026);

      expect(budget.consumeShellCall(now), isNull);
      expect(budget.shellCalls, 1);
      expect(budget.consumeShellCall(now)?.limit, AgentBudgetLimit.shellCalls);
      expect(budget.shellCalls, 1);
    });

    test('stops before side effects when its deadline has passed', () {
      final startedAt = DateTime(2026);
      final budget = AgentExecutionBudget(
        startedAt: startedAt,
        maxElapsed: const Duration(minutes: 1),
      );

      expect(
        budget.consumeModelRequest(startedAt.add(const Duration(minutes: 1))),
        isNull,
      );
      expect(
        budget
            .consumeShellCall(
              startedAt.add(const Duration(minutes: 1, milliseconds: 1)),
            )
            ?.limit,
        AgentBudgetLimit.elapsed,
      );
    });
  });
}
