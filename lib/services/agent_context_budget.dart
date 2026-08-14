import 'dart:convert';

import 'agent_tool_contract.dart';

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
    return (exactUsageTokens != null &&
            exactUsageTokens >= autoCompactAtTokens) ||
        estimatedTokens >= autoCompactAtTokens ||
        (exactUsageTokens == null && itemCount >= itemFallbackThreshold);
  }

  /// Conservative cross-provider estimate used until an adapter reports exact
  /// usage. UTF-8 bytes / 3 is deliberately safer for CJK and JSON-heavy tool
  /// payloads than the common English-only characters / 4 shortcut.
  static int estimateHistoryTokens(Iterable<AgentConversationItem> items) {
    var bytes = 0;
    for (final item in items) {
      bytes += utf8.encode(item.role ?? '').length;
      bytes += utf8.encode(item.content ?? '').length;
      for (final call in item.toolCalls) {
        bytes += utf8.encode(call.id).length;
        bytes += utf8.encode(call.name).length;
        bytes += utf8.encode(jsonEncode(call.arguments)).length;
      }
      for (final result in item.toolResults) {
        bytes += utf8.encode(result.toolCallId).length;
        bytes += utf8.encode(result.content).length;
      }
    }
    return (bytes / 3).ceil();
  }
}
