import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_context_budget.dart';

void main() {
  group('AgentContextBudget', () {
    test('uses the conservative default for an unknown model', () {
      final budget = AgentContextBudget.forContextWindow(null);

      expect(budget.contextWindowTokens, 32000);
      expect(budget.autoCompactAtTokens, 16000);
    });

    test('reserves summary headroom for known context windows', () {
      expect(
        AgentContextBudget.forContextWindow(64000).autoCompactAtTokens,
        40000,
      );
      expect(
        AgentContextBudget.forContextWindow(128000).autoCompactAtTokens,
        100000,
      );
      expect(
        AgentContextBudget.forContextWindow(200000).autoCompactAtTokens,
        172000,
      );
    });

    test('uses exact usage ahead of the item-count fallback', () {
      final budget = AgentContextBudget.forContextWindow(128000);

      expect(
        budget.shouldCompact(
          estimatedTokens: 1,
          exactUsageTokens: 99999,
          itemCount: 100,
        ),
        isFalse,
      );
    });

    test('uses eighty items as a fallback without exact usage', () {
      final budget = AgentContextBudget.forContextWindow(128000);

      expect(budget.shouldCompact(estimatedTokens: 1, itemCount: 80), isTrue);
    });
  });
}
