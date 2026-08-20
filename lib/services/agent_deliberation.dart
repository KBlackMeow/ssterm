import '../models/agent_config.dart';
import 'agent_decision_policy.dart';
import 'agent_tool_contract.dart';
import 'llm_service.dart';

class AgentDeliberationRequest {
  const AgentDeliberationRequest({
    required this.profile,
    required this.messages,
  });

  final AgentRequestProfile profile;
  final List<AgentConversationItem> messages;
}

/// Isolated model calls used to plan and critique a complex task. These calls
/// deliberately advertise no tools, so their output cannot directly act.
abstract final class AgentDeliberation {
  static const _plannerPrompt = '''You are a planning reviewer. You cannot use
tools or authorize changes. Return one JSON object only with `recommendedId`
and `candidates`. Provide 2 or 3 candidates; every candidate needs `id`,
`summary`, `risk`, and `validation`. Recommend the candidate that best balances
outcome, evidence, reversibility, cost, and maintenance.''';

  static AgentDeliberationRequest planRequest(String taskContext) =>
      AgentDeliberationRequest(
        profile: const AgentRequestProfile(
          systemPromptOverride: _plannerPrompt,
          allowedNativeToolNames: {},
        ),
        messages: [
          AgentConversationItem.text(role: 'user', content: taskContext),
        ],
      );

  static AgentDecisionPlan? parsePlan(String response) =>
      AgentDecisionPlan.tryParseJson(response.trim());

  static Future<AgentDecisionPlan?> plan({
    required AgentConfig config,
    required String taskContext,
  }) async {
    final request = planRequest(taskContext);
    final response = await LlmService.chat(
      config: config,
      messages: request.messages,
      profile: request.profile,
    );
    if (response.error != null || response.toolCalls.isNotEmpty) return null;
    return parsePlan(response.text);
  }

  static Future<AgentDecisionPlan?> critique({
    required AgentConfig config,
    required String taskContext,
    required AgentDecisionPlan plan,
  }) async {
    final response = await LlmService.chat(
      config: config,
      profile: const AgentRequestProfile(
        systemPromptOverride:
            'You are an independent critic. You cannot use tools or authorize '
            'changes. Return one corrected decision-plan JSON object only. '
            'Keep 2 or 3 candidates and challenge unsupported assumptions.',
        allowedNativeToolNames: {},
      ),
      messages: [
        AgentConversationItem.text(
          role: 'user',
          content: '$taskContext\n\nProposed plan:\n${plan.toJson()}',
        ),
      ],
    );
    if (response.error != null || response.toolCalls.isNotEmpty) return null;
    return parsePlan(response.text);
  }
}
