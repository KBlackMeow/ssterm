import 'agent_context_budget.dart';
import 'agent_tool_contract.dart';
import 'conversation_compactor.dart';

enum AgentCompactionOutcome { skipped, summarized, trimmed, obsolete }

/// Owns compaction decisions and transcript replacement without UI state.
class AgentConversationManager {
  const AgentConversationManager();

  Future<AgentCompactionOutcome> compactIfNeeded({
    required AgentConversationHistory history,
    required AgentContextBudget budget,
    required int? lastPromptTokenCount,
    required Future<String?> Function(String prompt) summarize,
    required bool Function() isCurrent,
    bool force = false,
    void Function()? onStart,
  }) async {
    final estimatedTokens = AgentContextBudget.estimateHistoryTokens(history);
    if (!force &&
        !budget.shouldCompact(
          estimatedTokens: estimatedTokens,
          exactUsageTokens: lastPromptTokenCount,
          itemCount: history.length,
        )) {
      return AgentCompactionOutcome.skipped;
    }
    const pinnedItems = 2;
    const fallbackItems = 80;
    final recentTokenBudget = (budget.contextWindowTokens * 0.2).round().clamp(
      2048,
      8000,
    );
    final candidate = history.compactionCandidate(
      pinnedItemCount: pinnedItems,
      recentItemCount: 16,
      recentTokenBudget: recentTokenBudget,
    );
    if (candidate.isEmpty) {
      if (!isCurrent()) return AgentCompactionOutcome.obsolete;
      history.trimToMaxItems(
        maxItems: fallbackItems,
        pinnedItemCount: pinnedItems,
      );
      return AgentCompactionOutcome.trimmed;
    }
    onStart?.call();
    final summary = await summarize(
      ConversationCompactor.buildPrompt(
        existingSummary: history.summaryContent ?? '',
        items: candidate,
      ),
    );
    if (!isCurrent()) return AgentCompactionOutcome.obsolete;
    if (summary != null) {
      history.replaceWithSummary(
        summary: summary,
        pinnedItemCount: pinnedItems,
        recentItemCount: 16,
        recentTokenBudget: recentTokenBudget,
      );
      return AgentCompactionOutcome.summarized;
    }
    history.trimToMaxItems(
      maxItems: fallbackItems,
      pinnedItemCount: pinnedItems,
    );
    return AgentCompactionOutcome.trimmed;
  }
}
