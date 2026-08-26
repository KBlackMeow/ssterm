import 'dart:convert';

/// Deterministic, model-independent policy for deciding when an Agent task
/// merits additional planning and verification calls.
enum AgentDecisionRoute { fast, deep, uncertain }

const _defaultMaxDeepModelRequests = 12;

class AgentDecisionSettings {
  const AgentDecisionSettings({
    required this.enabled,
    this.firstTurnToolFocus = false,
    this.maxDeepModelRequests = _defaultMaxDeepModelRequests,
    this.maxRecoveryModelRequests = 2,
  }) : assert(maxDeepModelRequests > 0),
       assert(maxRecoveryModelRequests >= 0);

  final bool enabled;
  final bool firstTurnToolFocus;
  final int maxDeepModelRequests;
  final int maxRecoveryModelRequests;

  Map<String, Object> toJson() => {
    'enabled': enabled,
    if (firstTurnToolFocus) 'firstTurnToolFocus': true,
    if (maxDeepModelRequests != _defaultMaxDeepModelRequests)
      'maxDeepModelRequests': maxDeepModelRequests,
    if (maxRecoveryModelRequests != 2)
      'maxRecoveryModelRequests': maxRecoveryModelRequests,
  };

  static AgentDecisionSettings? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final enabled = value['enabled'];
    if (enabled is! bool) return null;
    final deep = value['maxDeepModelRequests'];
    final recovery = value['maxRecoveryModelRequests'];
    if (deep != null && (deep is! int || deep <= 0)) return null;
    if (recovery != null && (recovery is! int || recovery < 0)) return null;
    return AgentDecisionSettings(
      enabled: enabled,
      firstTurnToolFocus: value['firstTurnToolFocus'] == true,
      maxDeepModelRequests: deep as int? ?? _defaultMaxDeepModelRequests,
      maxRecoveryModelRequests: recovery as int? ?? 2,
    );
  }
}

class AgentDecisionRun {
  AgentDecisionRun.deep(this.settings) : route = AgentDecisionRoute.deep;

  final AgentDecisionSettings settings;
  final AgentDecisionRoute route;
  final Set<String> _recoveryEvidence = <String>{};
  int modelRequests = 0;
  int recoveryRequests = 0;
  bool firstToolFocusPending = true;

  void markFirstToolResult() => firstToolFocusPending = false;

  int get _modelRequestLimit =>
      settings.maxDeepModelRequests +
      (recoveryRequests * settings.maxRecoveryModelRequests);

  int get remainingModelRequests => _modelRequestLimit - modelRequests;

  bool consumeModelRequest() {
    if (modelRequests >= _modelRequestLimit) return false;
    modelRequests++;
    return true;
  }

  bool requestRecovery({required String evidence}) {
    final normalized = evidence.trim();
    if (normalized.isEmpty ||
        recoveryRequests >= settings.maxRecoveryModelRequests ||
        !_recoveryEvidence.add(normalized)) {
      return false;
    }
    recoveryRequests++;
    return true;
  }
}

class AgentDecisionCandidate {
  const AgentDecisionCandidate({
    required this.id,
    required this.summary,
    required this.fit,
    required this.evidence,
    required this.cost,
    required this.maintenance,
    required this.risk,
    required this.validation,
  });

  final String id;
  final String summary;
  final String fit;
  final String evidence;
  final String cost;
  final String maintenance;
  final String risk;
  final String validation;

  factory AgentDecisionCandidate.tryFromJson(Object? value) {
    if (value is! Map) throw const FormatException();
    final id = value['id'];
    final summary = value['summary'];
    final fit = value['fit'];
    final evidence = value['evidence'];
    final cost = value['cost'];
    final maintenance = value['maintenance'];
    final risk = value['risk'];
    final validation = value['validation'];
    if (id is! String ||
        id.trim().isEmpty ||
        summary is! String ||
        summary.trim().isEmpty ||
        fit is! String ||
        fit.trim().isEmpty ||
        evidence is! String ||
        evidence.trim().isEmpty ||
        cost is! String ||
        cost.trim().isEmpty ||
        maintenance is! String ||
        maintenance.trim().isEmpty ||
        risk is! String ||
        risk.trim().isEmpty ||
        validation is! String ||
        validation.trim().isEmpty) {
      throw const FormatException();
    }
    return AgentDecisionCandidate(
      id: id.trim(),
      summary: summary.trim(),
      fit: fit.trim(),
      evidence: evidence.trim(),
      cost: cost.trim(),
      maintenance: maintenance.trim(),
      risk: risk.trim(),
      validation: validation.trim(),
    );
  }
}

class AgentDecisionPlan {
  const AgentDecisionPlan({
    required this.recommendedId,
    required this.candidates,
  });

  final String recommendedId;
  final List<AgentDecisionCandidate> candidates;

  static AgentDecisionPlan? tryParseJson(String text) {
    try {
      final value = jsonDecode(text);
      if (value is! Map) return null;
      final recommendedId = value['recommendedId'];
      final rawCandidates = value['candidates'];
      if (recommendedId is! String || rawCandidates is! List) return null;
      if (rawCandidates.length < 2 || rawCandidates.length > 3) return null;
      final candidates = rawCandidates
          .map(AgentDecisionCandidate.tryFromJson)
          .toList(growable: false);
      final ids = candidates.map((candidate) => candidate.id).toSet();
      if (ids.length != candidates.length || !ids.contains(recommendedId)) {
        return null;
      }
      return AgentDecisionPlan(
        recommendedId: recommendedId,
        candidates: candidates,
      );
    } on FormatException {
      return null;
    }
  }

  Map<String, Object> toJson() => {
    'recommendedId': recommendedId,
    'candidates': [
      for (final candidate in candidates)
        {
          'id': candidate.id,
          'summary': candidate.summary,
          'fit': candidate.fit,
          'evidence': candidate.evidence,
          'cost': candidate.cost,
          'maintenance': candidate.maintenance,
          'risk': candidate.risk,
          'validation': candidate.validation,
        },
    ],
  };
}

abstract final class AgentDecisionPolicy {
  /// These are deliberate depth *requests*, not task-topic signals. A
  /// deployment or comparison can be routine, so it must not bypass routing.
  static const _explicitDeepKeywords = <String>[
    'deep analysis',
    'deeply analyze',
    'think deeply',
    'in-depth',
    'thorough analysis',
    '深入分析',
    '深度分析',
    '深思熟虑',
    '全面推演',
  ];

  /// Obvious one-step lookups do not need a model round-trip to establish
  /// their complexity. Everything else that is not explicitly deep is left to
  /// the routing Agent.
  static final _directRequest = RegExp(
    r'^(show|list|print|display|what is|where is|pwd\b|显示|列出|查看|当前目录)',
    caseSensitive: false,
  );

  static AgentDecisionRoute classify(
    String task,
    AgentDecisionSettings settings,
  ) {
    if (!settings.enabled || task.trim().isEmpty) {
      return AgentDecisionRoute.fast;
    }
    final normalized = task.toLowerCase();
    if (_explicitDeepKeywords.any(normalized.contains)) {
      return AgentDecisionRoute.deep;
    }
    if (_directRequest.hasMatch(normalized.trim())) {
      return AgentDecisionRoute.fast;
    }
    return AgentDecisionRoute.uncertain;
  }

  static String guideFor(AgentDecisionRoute route) => switch (route) {
    AgentDecisionRoute.fast =>
      'Use direct, verifiable steps. Finish when the evidence is sufficient.',
    AgentDecisionRoute.deep =>
      'Think deeply about architecture, constraints, edge cases, and '
          'integration points. Do not spend reasoning on the environment or '
          'tooling. End each reasoning block with a decision or an information '
          'need. Review completed work; do not perform unguided environment '
          'inspection or exhaustive search. In the final answer include '
          'Recommendation, Alternatives considered, Evidence, and Remaining risk.',
    AgentDecisionRoute.uncertain =>
      'Gather the minimum evidence needed to decide whether deeper planning '
          'is necessary.',
  };
}
