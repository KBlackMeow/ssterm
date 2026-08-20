import 'dart:convert';

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

class AgentVerificationVerdict {
  const AgentVerificationVerdict({
    required this.complete,
    required this.evidence,
    this.recovery,
  });

  final bool complete;
  final String evidence;
  final String? recovery;
}

/// Isolated model calls used to plan and critique a complex task. These calls
/// deliberately advertise no tools, so their output cannot directly act.
abstract final class AgentDeliberation {
  static const _plannerPrompt = '''You are a planning reviewer. You cannot use
tools or authorize changes. Return one JSON object only with `recommendedId`
and `candidates`. Provide 2 or 3 candidates; every candidate needs `id`,
`summary`, `fit`, `evidence`, `cost`, `maintenance`, `risk`, and `validation`.
Recommend the candidate that best balances outcome, evidence, reversibility,
cost, and maintenance.''';

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
            'Keep 2 or 3 candidates, preserve every comparison field, and '
            'challenge unsupported assumptions.',
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

  static AgentVerificationVerdict? parseVerdict(String response) {
    try {
      final value = jsonDecode(response);
      if (value is! Map || value['complete'] is! bool) return null;
      final evidence = value['evidence'];
      final recovery = value['recovery'];
      if (evidence is! String || evidence.trim().isEmpty) return null;
      if (recovery != null &&
          (recovery is! String || recovery.trim().isEmpty)) {
        return null;
      }
      return AgentVerificationVerdict(
        complete: value['complete'] as bool,
        evidence: evidence.trim(),
        recovery: recovery is String ? recovery.trim() : null,
      );
    } on FormatException {
      return null;
    }
  }

  static Future<AgentVerificationVerdict?> verify({
    required AgentConfig config,
    required AgentDecisionPlan plan,
    required String finalAnswer,
    required String evidence,
  }) async {
    final response = await LlmService.chat(
      config: config,
      profile: const AgentRequestProfile(
        systemPromptOverride:
            'You are a verifier. You cannot use tools or authorize changes. '
            'Return exactly one JSON object: complete (boolean), evidence '
            '(string), and optional recovery (string). Mark complete only when '
            'the supplied evidence proves the plan validation conditions.',
        allowedNativeToolNames: {},
      ),
      messages: [
        AgentConversationItem.text(
          role: 'user',
          content:
              'Plan: ${plan.toJson()}\n\nFinal answer: $finalAnswer\n\nTool evidence: $evidence',
        ),
      ],
    );
    if (response.error != null || response.toolCalls.isNotEmpty) return null;
    return parseVerdict(response.text);
  }
}
