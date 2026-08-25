import 'agent_decision_policy.dart';

/// User-readable, client-generated progress messages for adaptive decisions.
///
/// This deliberately formats only the parsed decision fields. Planner prompts,
/// raw JSON, and model reasoning remain internal implementation details.
abstract final class AgentDecisionTranscript {
  static String planning(AgentDecisionPlan plan) => [
    '已完成方案梳理：',
    for (final candidate in plan.candidates)
      '- 方案 ${candidate.id}：${candidate.summary}\n'
          '  适用性：${candidate.fit}\n'
          '  风险：${candidate.risk}',
  ].join('\n');

  static String recommendation(AgentDecisionPlan plan) {
    final candidate = plan.candidates.firstWhere(
      (item) => item.id == plan.recommendedId,
    );
    return '建议采用：${candidate.summary}\n'
        '依据：${candidate.evidence}\n'
        '验证方式：${candidate.validation}';
  }
}
