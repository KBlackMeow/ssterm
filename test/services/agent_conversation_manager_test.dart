import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_context_budget.dart';
import 'package:ssterm/services/agent_conversation_manager.dart';
import 'package:ssterm/services/agent_tool_contract.dart';

AgentConversationHistory longHistory() => AgentConversationHistory()
  ..add(const {'role': 'user', 'content': 'Goal: fix the parser'})
  ..add(const {'role': 'assistant', 'content': 'I will inspect it.'})
  ..add({'role': 'user', 'content': 'old output ${'a' * 15000}'})
  ..add({'role': 'assistant', 'content': 'middle work ${'b' * 15000}'})
  ..add({'role': 'user', 'content': 'latest evidence ${'c' * 15000}'});

void main() {
  final budget = AgentContextBudget.forContextWindow(64000);

  test('compaction preserves the goal and recent evidence', () async {
    final history = longHistory();
    var called = false;
    final outcome = await const AgentConversationManager().compactIfNeeded(
      history: history,
      budget: budget,
      lastPromptTokenCount: null,
      force: true,
      isCurrent: () => true,
      onStart: () => called = true,
      summarize: (prompt) async {
        expect(prompt, contains('old output'));
        return 'Parser investigation in progress.';
      },
    );
    expect(called, isTrue);
    expect(outcome, AgentCompactionOutcome.summarized);
    expect(history.first.content, contains('Goal: fix the parser'));
    expect(history.summaryContent, contains('Parser investigation'));
    expect(history.last.content, contains('latest evidence'));
  });

  test('cancelled compaction does not change the transcript', () async {
    final history = longHistory();
    final before = history.map((item) => item.content).toList();
    final outcome = await const AgentConversationManager().compactIfNeeded(
      history: history,
      budget: budget,
      lastPromptTokenCount: null,
      force: true,
      isCurrent: () => false,
      summarize: (_) async => 'summary',
    );
    expect(outcome, AgentCompactionOutcome.obsolete);
    expect(history.map((item) => item.content).toList(), before);
  });
}
