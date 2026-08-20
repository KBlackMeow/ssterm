import 'dart:convert';

/// Deterministic, model-independent policy for deciding when an Agent task
/// merits additional planning and verification calls.
enum AgentDecisionRoute { fast, deep, uncertain }

class AgentDecisionSettings {
  const AgentDecisionSettings({
    required this.enabled,
    this.firstTurnToolFocus = false,
    this.maxDeepModelRequests = 5,
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
    if (maxDeepModelRequests != 5) 'maxDeepModelRequests': maxDeepModelRequests,
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
      maxDeepModelRequests: deep as int? ?? 5,
      maxRecoveryModelRequests: recovery as int? ?? 2,
    );
  }
}

class AgentDecisionRun {
  AgentDecisionRun.deep(this.settings) : route = AgentDecisionRoute.deep;

  final AgentDecisionSettings settings;
  final AgentDecisionRoute route;
  final Set<String> _recoveryEvidence = <String>{};
  int recoveryRequests = 0;

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
    required this.risk,
    required this.validation,
  });

  final String id;
  final String summary;
  final String risk;
  final String validation;

  factory AgentDecisionCandidate.tryFromJson(Object? value) {
    if (value is! Map) throw const FormatException();
    final id = value['id'];
    final summary = value['summary'];
    final risk = value['risk'];
    final validation = value['validation'];
    if (id is! String ||
        id.trim().isEmpty ||
        summary is! String ||
        summary.trim().isEmpty ||
        risk is! String ||
        risk.trim().isEmpty ||
        validation is! String ||
        validation.trim().isEmpty) {
      throw const FormatException();
    }
    return AgentDecisionCandidate(
      id: id.trim(),
      summary: summary.trim(),
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
          'risk': candidate.risk,
          'validation': candidate.validation,
        },
    ],
  };
}

abstract final class AgentDecisionPolicy {
  static const _deepSignals = <String>[
    'compare',
    'recommend',
    'alternative',
    'migration',
    'deployment',
    'deploy',
    'architecture',
    'risk',
    'cost',
    'recover',
    'failure',
    '比较',
    '推荐',
    '方案',
    '风险',
    '成本',
    '故障',
  ];

  static AgentDecisionRoute classify(
    String task,
    AgentDecisionSettings settings,
  ) {
    if (!settings.enabled || task.trim().isEmpty)
      return AgentDecisionRoute.fast;
    final normalized = task.toLowerCase();
    if (_deepSignals.any(normalized.contains)) return AgentDecisionRoute.deep;
    return AgentDecisionRoute.fast;
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
