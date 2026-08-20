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
}

class AgentDecisionRun {
  AgentDecisionRun.deep(this.settings)
    : route = AgentDecisionRoute.deep;

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
    if (!settings.enabled || task.trim().isEmpty) return AgentDecisionRoute.fast;
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
      'inspection or exhaustive search.',
    AgentDecisionRoute.uncertain =>
      'Gather the minimum evidence needed to decide whether deeper planning '
      'is necessary.',
  };
}
