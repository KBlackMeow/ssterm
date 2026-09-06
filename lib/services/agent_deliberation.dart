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

class AgentCritiqueVerdict {
  const AgentCritiqueVerdict({
    required this.accept,
    this.issue,
    this.replacementId,
  });

  final bool accept;
  final String? issue;
  final String? replacementId;
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
cannot use tools or authorize changes. Return only minified JSON, with no
Markdown, prose, or extra keys: `{"route":"direct"}`. The value must be
exactly `direct`, `standard`, or `deep`.

Choose `direct` for one obvious read-only operation. Choose `standard` for a
clear single-path change, even when it needs several execution steps. Choose
`deep` when the agent must first create and
execute a solution workflow: identify unknowns, compare material options, make
architecture or operational tradeoffs, manage high-impact risk, or coordinate
dependent steps and validation. Do not require the user to say "deep". Be
conservative, but do not discard a genuinely complex problem merely because it
does not use planning keywords.''';

  static const _plannerPrompt =
      '''You are a concise planning reviewer. You cannot use
tools or authorize changes. Return one JSON object only with `recommendedId`
and exactly 2 `candidates`. Every candidate needs only `id`, `summary`,
`evidence`, `risk`, and `validation`.
Recommend the candidate that best balances outcome, evidence, reversibility,
cost, and maintenance. Keep every string brief.''';

  static AgentDeliberationRequest planRequest(String taskContext) =>
      AgentDeliberationRequest(
        profile: const AgentRequestProfile(
          systemPromptOverride: _plannerPrompt,
          allowedNativeToolNames: {},
          maxOutputTokens: 384,
          reasoningLevel: AgentReasoningLevel.medium,
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
          maxOutputTokens: 96,
          reasoningLevel: AgentReasoningLevel.disabled,
        ),
        messages: [
          AgentConversationItem.text(role: 'user', content: taskContext),
        ],
      );

  static AgentRouteDecision? parseRoute(String response) {
    final extracted = _extractJsonObject(response);
    try {
      final value = jsonDecode(extracted);
      if (value is! Map) return _parseLooseRoute(response);
      final route = _routeFromValue(
        value['route'] ?? value['mode'] ?? value['decision'],
      );
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
    } on Object {
      return _parseLooseRoute(response);
    }
  }

  static AgentRouteDecision? _parseLooseRoute(String response) {
    final normalized = response.trim().toLowerCase();
    final standalone = _routeFromValue(normalized);
    if (standalone != null) {
      return AgentRouteDecision(
        route: standalone,
        confidence: 0.5,
        signals: const [],
      );
    }
    final match = RegExp(
      r'''(?:route|mode|decision)\W{0,8}(direct|simple|fast|standard|normal|deep|complex|deliberate)\b''',
      caseSensitive: false,
    ).firstMatch(response);
    final route = match == null ? null : _routeFromValue(match.group(1));
    return route == null
        ? null
        : AgentRouteDecision(route: route, confidence: 0.5, signals: const []);
  }

  static AgentDecisionRoute? _routeFromValue(Object? value) {
    if (value is! String) return null;
    return switch (value.trim().toLowerCase().replaceAll(
      RegExp(r'[_\s-]'),
      '',
    )) {
      'direct' || 'simple' => AgentDecisionRoute.direct,
      // Accept old router responses during rolling upgrades.
      'fast' || 'standard' || 'normal' => AgentDecisionRoute.standard,
      'deep' || 'complex' || 'deliberate' => AgentDecisionRoute.deep,
      _ => null,
    };
  }

  /// Model providers often wrap an otherwise valid routing payload in a JSON
  /// fence or a brief sentence. Accept the object instead of silently routing
  /// the task to standard execution.
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
    final decision = response.error != null || response.toolCalls.isNotEmpty
        ? null
        : parseRoute(response.text);

    // Routing only chooses how much deliberation to spend; it must never stop
    // a valid task because a provider returned empty text or ignored the JSON
    // format instruction. Standard execution is the safe, no-extra-token
    // fallback for an unparseable but otherwise successful response.
    final safeFallback =
        response.error == null &&
        response.toolCalls.isEmpty &&
        decision == null;
    return AgentDeliberationResult(
      value:
          decision ??
          (safeFallback
              ? const AgentRouteDecision(
                  route: AgentDecisionRoute.standard,
                  confidence: 0.5,
                  signals: [],
                )
              : null),
      usage: response.usage,
      error: response.error,
    );
  }

  static AgentDeliberationRequest critiqueRequest({
    required String taskContext,
    required AgentDecisionPlan plan,
  }) => AgentDeliberationRequest(
    profile: const AgentRequestProfile(
      systemPromptOverride:
          'You are an independent critic. You cannot use tools or authorize '
          'changes. Return exactly one compact JSON object with accept '
          '(boolean), issue (string or null), and replacementId (candidate id '
          'or null). Do not repeat or rewrite the plan. Challenge only '
          'material unsupported assumptions.',
      allowedNativeToolNames: {},
      maxOutputTokens: 256,
      reasoningLevel: AgentReasoningLevel.medium,
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

  static AgentCritiqueVerdict? parseCritique(String response) {
    try {
      final value = jsonDecode(_extractJsonObject(response));
      if (value is! Map || value['accept'] is! bool) return null;
      final issue = value['issue'];
      final replacementId = value['replacementId'];
      if (issue != null && issue is! String) return null;
      if (replacementId != null && replacementId is! String) return null;
      return AgentCritiqueVerdict(
        accept: value['accept'] as bool,
        issue: issue is String && issue.trim().isNotEmpty ? issue.trim() : null,
        replacementId:
            replacementId is String && replacementId.trim().isNotEmpty
            ? replacementId.trim()
            : null,
      );
    } on FormatException {
      return null;
    }
  }

  static Future<AgentDeliberationResult<AgentCritiqueVerdict>> critique({
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
          : parseCritique(response.text),
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

  static Future<AgentDeliberationResult<AgentCritiqueVerdict>> streamCritique({
    required AgentConfig config,
    required String taskContext,
    required AgentDecisionPlan plan,
    required AgentStreamClientSession session,
    required void Function(String text) onText,
    void Function(AgentDeliberationStreamUpdate update)? onUpdate,
  }) async {
    final request = critiqueRequest(taskContext: taskContext, plan: plan);
    try {
      final response = LlmService.chatStream(
        config: config,
        messages: request.messages,
        session: session,
        profile: request.profile,
      );
      return await _collectStream(
        response.stream,
        onText,
        parser: parseCritique,
        invalidError: 'The stream returned an invalid critique response.',
        onUpdate: onUpdate,
      );
    } catch (_) {
      return const AgentDeliberationResult(
        value: null,
        usage: ProviderTokenUsage(),
        error: 'Unable to start critique stream.',
      );
    }
  }

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
  }) => _collectStream(
    stream,
    onText,
    parser: parsePlan,
    invalidError: 'The stream returned an invalid decision response.',
    onUpdate: onUpdate,
  );

  static Future<AgentDeliberationResult<T>> _collectStream<T>(
    Stream<LlmStreamEvent> stream,
    void Function(String text) onText, {
    required T? Function(String response) parser,
    required String invalidError,
    void Function(AgentDeliberationStreamUpdate update)? onUpdate,
  }) async {
    final buffer = StringBuffer();
    int? promptTokenCount;
    int? completionTokenCount;
    int? reasoningTokenCount;
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
          reasoningTokenCount =
              event.reasoningTokenCount ?? reasoningTokenCount;
        }
      }
    } catch (error) {
      return AgentDeliberationResult(
        value: null,
        usage: ProviderTokenUsage(
          promptTokenCount: promptTokenCount,
          completionTokenCount: completionTokenCount,
          reasoningTokenCount: reasoningTokenCount,
        ),
        error: error.toString(),
      );
    }
    final value = parser(buffer.toString());
    return AgentDeliberationResult(
      value: value,
      usage: ProviderTokenUsage(
        promptTokenCount: promptTokenCount,
        completionTokenCount: completionTokenCount,
        reasoningTokenCount: reasoningTokenCount,
      ),
      error: buffer.isEmpty
          ? 'The stream ended without text.'
          : value == null
          ? invalidError
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
        maxOutputTokens: 160,
        reasoningLevel: AgentReasoningLevel.low,
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
