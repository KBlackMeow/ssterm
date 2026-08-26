import 'dart:convert';

import '../models/agent_config.dart';
import 'agent_decision_policy.dart';
import 'agent_stream_client_session.dart';
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

/// The outcome of the lightweight, tool-free routing call.
class AgentRouteDecision {
  const AgentRouteDecision({
    required this.route,
    required this.confidence,
    required this.signals,
  });

  final AgentDecisionRoute route;
  final double confidence;
  final List<String> signals;
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

class AgentDeliberationResult<T> {
  const AgentDeliberationResult({
    required this.value,
    required this.usage,
    this.error,
  });

  final T? value;
  final ProviderTokenUsage usage;
  final String? error;
}

class AgentDeliberationStreamUpdate {
  const AgentDeliberationStreamUpdate({
    required this.kind,
    required this.content,
  });

  final String kind;
  final String content;

  bool get isReasoning => kind == 'reasoning';
  bool get isText => kind == 'text';
}

/// Isolated model calls used to plan and critique a complex task. These calls
/// deliberately advertise no tools, so their output cannot directly act.
abstract final class AgentDeliberation {
  static const _routerPrompt = '''You are a conservative task router. You
cannot use tools or authorize changes. Return exactly one JSON object:
`{"route":"fast"|"deep","confidence":0.0-1.0,"signals":["..."]}`.

Choose `fast` when one direct tool operation or a clear, single-path change
will fulfill the request. Choose `deep` when the agent must first create and
execute a solution workflow: identify unknowns, compare material options, make
architecture or operational tradeoffs, manage high-impact risk, or coordinate
dependent steps and validation. Do not require the user to say "deep". Be
conservative, but do not discard a genuinely complex problem merely because it
does not use planning keywords. Signals must be short, concrete evidence from
the request (for example `multiple_options`, `rollback_required`, or
`cross_service_dependencies`).''';

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

  static AgentDeliberationRequest routeRequest(String taskContext) =>
      AgentDeliberationRequest(
        profile: const AgentRequestProfile(
          systemPromptOverride: _routerPrompt,
          allowedNativeToolNames: {},
        ),
        messages: [
          AgentConversationItem.text(role: 'user', content: taskContext),
        ],
      );

  static AgentRouteDecision? parseRoute(String response) {
    try {
      final value = jsonDecode(_extractJsonObject(response));
      if (value is! Map || value['route'] is! String) return null;
      final route = switch (value['route']) {
        'fast' => AgentDecisionRoute.fast,
        'deep' => AgentDecisionRoute.deep,
        _ => null,
      };
      if (route == null) return null;
      final rawConfidence = value['confidence'];
      final confidence = rawConfidence is num
          ? rawConfidence.toDouble().clamp(0.0, 1.0)
          : 0.5;
      final rawSignals = value['signals'];
      final signals = rawSignals is List
          ? rawSignals
                .whereType<String>()
                .map((signal) => signal.trim())
                .where((signal) => signal.isNotEmpty)
                .take(3)
                .toList(growable: false)
          : const <String>[];
      return AgentRouteDecision(
        route: route,
        confidence: confidence,
        signals: signals,
      );
    } on FormatException {
      return null;
    }
  }

  /// Model providers often wrap an otherwise valid routing payload in a JSON
  /// fence or a brief sentence. Accept the object instead of silently routing
  /// the task to fast execution.
  static String _extractJsonObject(String response) {
    final trimmed = response.trim();
    final fenced = RegExp(
      r'```(?:json)?\s*([\s\S]*?)\s*```',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (fenced != null) return fenced.group(1)!.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    return start >= 0 && end > start
        ? trimmed.substring(start, end + 1)
        : trimmed;
  }

  /// Invalid or failed routing is deliberately treated as fast by the caller,
  /// avoiding surprise planning work or extra cost.
  static Future<AgentDeliberationResult<AgentRouteDecision>> route({
    required AgentConfig config,
    required String taskContext,
  }) async {
    final request = routeRequest(taskContext);
    final response = await LlmService.chat(
      config: config,
      messages: request.messages,
      profile: request.profile,
    );
    return AgentDeliberationResult(
      value: response.error != null || response.toolCalls.isNotEmpty
          ? null
          : parseRoute(response.text),
      usage: response.usage,
      error:
          response.error ??
          (response.toolCalls.isEmpty && parseRoute(response.text) == null
              ? 'The routing response was invalid.'
              : null),
    );
  }

  static AgentDeliberationRequest critiqueRequest({
    required String taskContext,
    required AgentDecisionPlan plan,
  }) => AgentDeliberationRequest(
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

  static AgentDecisionPlan? parsePlan(String response) =>
      AgentDecisionPlan.tryParseJson(response.trim());

  static Future<AgentDeliberationResult<AgentDecisionPlan>> plan({
    required AgentConfig config,
    required String taskContext,
  }) async {
    final request = planRequest(taskContext);
    final response = await LlmService.chat(
      config: config,
      messages: request.messages,
      profile: request.profile,
    );
    return AgentDeliberationResult(
      value: response.error != null || response.toolCalls.isNotEmpty
          ? null
          : parsePlan(response.text),
      usage: response.usage,
    );
  }

  static Future<AgentDeliberationResult<AgentDecisionPlan>> critique({
    required AgentConfig config,
    required String taskContext,
    required AgentDecisionPlan plan,
  }) async {
    final request = critiqueRequest(taskContext: taskContext, plan: plan);
    final response = await LlmService.chat(
      config: config,
      profile: request.profile,
      messages: request.messages,
    );
    return AgentDeliberationResult(
      value: response.error != null || response.toolCalls.isNotEmpty
          ? null
          : parsePlan(response.text),
      usage: response.usage,
    );
  }

  static Future<AgentDeliberationResult<AgentDecisionPlan>> streamPlan({
    required AgentConfig config,
    required String taskContext,
    required AgentStreamClientSession session,
    required void Function(String text) onText,
    void Function(AgentDeliberationStreamUpdate update)? onUpdate,
  }) => _streamPlanRequest(
    config: config,
    request: planRequest(taskContext),
    session: session,
    onText: onText,
    onUpdate: onUpdate,
  );

  static Future<AgentDeliberationResult<AgentDecisionPlan>> streamCritique({
    required AgentConfig config,
    required String taskContext,
    required AgentDecisionPlan plan,
    required AgentStreamClientSession session,
    required void Function(String text) onText,
    void Function(AgentDeliberationStreamUpdate update)? onUpdate,
  }) => _streamPlanRequest(
    config: config,
    request: critiqueRequest(taskContext: taskContext, plan: plan),
    session: session,
    onText: onText,
    onUpdate: onUpdate,
  );

  static Future<AgentDeliberationResult<AgentDecisionPlan>> _streamPlanRequest({
    required AgentConfig config,
    required AgentDeliberationRequest request,
    required AgentStreamClientSession session,
    required void Function(String text) onText,
    void Function(AgentDeliberationStreamUpdate update)? onUpdate,
  }) async {
    try {
      final response = LlmService.chatStream(
        config: config,
        messages: request.messages,
        session: session,
        profile: request.profile,
      );
      return await collectPlanStream(
        response.stream,
        onText,
        onUpdate: onUpdate,
      );
    } catch (error) {
      return const AgentDeliberationResult(
        value: null,
        usage: ProviderTokenUsage(),
        error: 'Unable to start deliberation stream.',
      );
    }
  }

  /// Consumes a tool-free planner/reviewer stream while exposing only its
  /// textual JSON payload to the UI. Reasoning events stay internal.
  static Future<AgentDeliberationResult<AgentDecisionPlan>> collectPlanStream(
    Stream<LlmStreamEvent> stream,
    void Function(String text) onText, {
    void Function(AgentDeliberationStreamUpdate update)? onUpdate,
  }) async {
    final buffer = StringBuffer();
    int? promptTokenCount;
    int? completionTokenCount;
    try {
      await for (final event in stream) {
        if ((event.kind == 'text' || event.kind == 'reasoning') &&
            event.content.isNotEmpty) {
          onUpdate?.call(
            AgentDeliberationStreamUpdate(
              kind: event.kind,
              content: event.content,
            ),
          );
          if (event.kind == 'text') {
            buffer.write(event.content);
            onText(event.content);
          }
        } else if (event.kind == 'diagnostics') {
          promptTokenCount = event.promptTokenCount ?? promptTokenCount;
          completionTokenCount =
              event.completionTokenCount ?? completionTokenCount;
        }
      }
    } catch (error) {
      return AgentDeliberationResult(
        value: null,
        usage: ProviderTokenUsage(
          promptTokenCount: promptTokenCount,
          completionTokenCount: completionTokenCount,
        ),
        error: error.toString(),
      );
    }
    final plan = parsePlan(buffer.toString());
    return AgentDeliberationResult(
      value: plan,
      usage: ProviderTokenUsage(
        promptTokenCount: promptTokenCount,
        completionTokenCount: completionTokenCount,
      ),
      error: buffer.isEmpty
          ? 'The stream ended without text.'
          : plan == null
          ? 'The stream returned an invalid decision response.'
          : null,
    );
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

  static Future<AgentDeliberationResult<AgentVerificationVerdict>> verify({
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
    return AgentDeliberationResult(
      value: response.error != null || response.toolCalls.isNotEmpty
          ? null
          : parseVerdict(response.text),
      usage: response.usage,
    );
  }
}
