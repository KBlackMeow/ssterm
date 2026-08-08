/// Model-aware token limits for agent conversation compaction.
class AgentContextBudget {
  const AgentContextBudget._({
    required this.contextWindowTokens,
    required this.summaryReserveTokens,
    required this.autoCompactAtTokens,
    required this.hardLimitTokens,
    required this.isFallbackWindow,
  });

  static const fallbackContextWindowTokens = 32000;
  static const fallbackAutoCompactAtTokens = 16000;
  static const itemFallbackThreshold = 80;

  final int contextWindowTokens;
  final int summaryReserveTokens;
  final int autoCompactAtTokens;
  final int hardLimitTokens;
  final bool isFallbackWindow;

  factory AgentContextBudget.forContextWindow(int? contextWindowTokens) {
    if (contextWindowTokens == null || contextWindowTokens <= 0) {
      return const AgentContextBudget._(
        contextWindowTokens: fallbackContextWindowTokens,
        summaryReserveTokens: 4000,
        autoCompactAtTokens: fallbackAutoCompactAtTokens,
        hardLimitTokens: 28800,
        isFallbackWindow: true,
      );
    }
    final reserve = (contextWindowTokens * 0.1875).round().clamp(4000, 16000);
    return AgentContextBudget._(
      contextWindowTokens: contextWindowTokens,
      summaryReserveTokens: reserve,
      autoCompactAtTokens: contextWindowTokens - reserve - 12000,
      hardLimitTokens: (contextWindowTokens * 0.9).floor(),
      isFallbackWindow: false,
    );
  }

  bool shouldCompact({
    required int estimatedTokens,
    int? exactUsageTokens,
    required int itemCount,
  }) {
    if (exactUsageTokens != null) {
      return exactUsageTokens >= autoCompactAtTokens;
    }
    return estimatedTokens >= autoCompactAtTokens ||
        itemCount >= itemFallbackThreshold;
  }
}
