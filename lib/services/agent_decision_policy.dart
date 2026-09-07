import 'dart:convert';

/// Deterministic, model-independent policy for deciding when an Agent task
/// merits additional planning and verification calls.
enum AgentDecisionRoute { direct, standard, deep, uncertain }

const _defaultMaxExecutionModelRequests = 8;
const _defaultMaxDecisionModelRequests = 2;

class AgentDecisionSettings {
  const AgentDecisionSettings({
    required this.enabled,
    this.firstTurnToolFocus = false,
    this.maxExecutionModelRequests = _defaultMaxExecutionModelRequests,
    this.maxDecisionModelRequests = _defaultMaxDecisionModelRequests,
    this.maxRecoveryRounds = 1,
  }) : assert(maxExecutionModelRequests > 0),
       assert(maxDecisionModelRequests > 0),
       assert(maxRecoveryRounds >= 0);

  final bool enabled;
  final bool firstTurnToolFocus;
  final int maxExecutionModelRequests;
  final int maxDecisionModelRequests;
  final int maxRecoveryRounds;

  Map<String, Object> toJson() => {
    'enabled': enabled,
    if (firstTurnToolFocus) 'firstTurnToolFocus': true,
    if (maxExecutionModelRequests != _defaultMaxExecutionModelRequests)
      'maxExecutionModelRequests': maxExecutionModelRequests,
    if (maxDecisionModelRequests != _defaultMaxDecisionModelRequests)
      'maxDecisionModelRequests': maxDecisionModelRequests,
    if (maxRecoveryRounds != 1) 'maxRecoveryRounds': maxRecoveryRounds,
  };

  static AgentDecisionSettings? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final enabled = value['enabled'];
    if (enabled is! bool) return null;
    final execution =
        value['maxExecutionModelRequests'] ?? value['maxDeepModelRequests'];
    final decision = value['maxDecisionModelRequests'];
    final recovery =
        value['maxRecoveryRounds'] ?? value['maxRecoveryModelRequests'];
    if (execution != null && (execution is! int || execution <= 0)) {
      return null;
    }
    if (decision != null && (decision is! int || decision <= 0)) return null;
    if (recovery != null && (recovery is! int || recovery < 0)) return null;
    return AgentDecisionSettings(
      enabled: enabled,
      firstTurnToolFocus: value['firstTurnToolFocus'] == true,
      maxExecutionModelRequests:
          execution as int? ?? _defaultMaxExecutionModelRequests,
      maxDecisionModelRequests:
          decision as int? ?? _defaultMaxDecisionModelRequests,
      maxRecoveryRounds: recovery as int? ?? 1,
    );
  }
}

class AgentDecisionRun {
  AgentDecisionRun.deep(this.settings, {this.highRisk = false})
    : route = AgentDecisionRoute.deep;

  final AgentDecisionSettings settings;
  final AgentDecisionRoute route;
  final bool highRisk;
  bool _elevatedRisk = false;
  final Set<String> _recoveryEvidence = <String>{};
  int decisionRequests = 0;
  int executionRequests = 0;
  int recoveryRounds = 0;
  bool firstToolFocusPending = true;

  void markFirstToolResult() => firstToolFocusPending = false;

  int get decisionRequestLimit =>
      settings.maxDecisionModelRequests + (highRisk || _elevatedRisk ? 1 : 0);

  void elevateRisk() => _elevatedRisk = true;

  int get remainingExecutionRequests =>
      settings.maxExecutionModelRequests - executionRequests;

  bool consumeDecisionRequest() {
    if (decisionRequests >= decisionRequestLimit) return false;
    decisionRequests++;
    return true;
  }

  bool consumeExecutionRequest() {
    if (executionRequests >= settings.maxExecutionModelRequests) return false;
    executionRequests++;
    return true;
  }

  bool requestRecovery({required String evidence}) {
    final normalized = evidence.trim();
    if (normalized.isEmpty ||
        recoveryRounds >= settings.maxRecoveryRounds ||
        !_recoveryEvidence.add(normalized)) {
      return false;
    }
    recoveryRounds++;
    return true;
  }
}

class AgentDecisionCandidate {
  const AgentDecisionCandidate({
    required this.id,
    required this.summary,
    required this.evidence,
    required this.risk,
    required this.validation,
  });

  final String id;
  final String summary;
  final String evidence;
  final String risk;
  final String validation;

  factory AgentDecisionCandidate.tryFromJson(Object? value) {
    if (value is! Map) throw const FormatException();
    final id = value['id'];
    final summary = value['summary'];
    final evidence = value['evidence'];
    final risk = value['risk'];
    final validation = value['validation'];
    if (id is! String ||
        id.trim().isEmpty ||
        summary is! String ||
        summary.trim().isEmpty ||
        evidence is! String ||
        evidence.trim().isEmpty ||
        risk is! String ||
        risk.trim().isEmpty ||
        validation is! String ||
        validation.trim().isEmpty) {
      throw const FormatException();
    }
    return AgentDecisionCandidate(
      id: id.trim(),
      summary: summary.trim(),
      evidence: evidence.trim(),
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

  AgentDecisionPlan withRecommendedId(String? id) {
    if (id == null || !candidates.any((candidate) => candidate.id == id)) {
      return this;
    }
    return AgentDecisionPlan(recommendedId: id, candidates: candidates);
  }

  static AgentDecisionPlan? tryParseJson(String text) {
    try {
      final value = jsonDecode(text);
      if (value is! Map) return null;
      final recommendedId = value['recommendedId'];
      final rawCandidates = value['candidates'];
      if (recommendedId is! String || rawCandidates is! List) return null;
      if (rawCandidates.length != 2) return null;
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
          'evidence': candidate.evidence,
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

  static final _highRiskRequest = RegExp(
    r'\b(production|prod|credential|permission|database migration|drop table|delete account|rollback|irreversible)\b|生产环境|凭据|权限|数据库迁移|删库|不可逆|回滚',
    caseSensitive: false,
  );

  static final _comparisonRequest = RegExp(
    r'\b(compare|choose between|trade-?offs?|architecture|redesign|recommend|options?|alternatives?)\b|比较.*方案|方案对比|权衡|架构设计|重新设计|推荐|选项|备选方案',
    caseSensitive: false,
  );

  static final _changeRequest = RegExp(
    r'\b(fix|implement|add|update|change|refactor|test|diagnose|remove)\b|修复|实现|新增|更新|修改|重构|测试|诊断|移除',
    caseSensitive: false,
  );

  static bool isHighRisk(String task) => _highRiskRequest.hasMatch(task);

  static AgentDecisionRoute classify(
    String task,
    AgentDecisionSettings settings,
  ) {
    if (!settings.enabled || task.trim().isEmpty) {
      return AgentDecisionRoute.direct;
    }
    final normalized = task.toLowerCase();
    if (_explicitDeepKeywords.any(normalized.contains)) {
      return AgentDecisionRoute.deep;
    }
    // Material-choice signals must outrank surface forms such as "show" or
    // "list". Otherwise "show migration trade-offs" silently bypasses the
    // decision workflow.
    if (_comparisonRequest.hasMatch(normalized)) {
      return AgentDecisionRoute.deep;
    }
    if (_directRequest.hasMatch(normalized.trim()) &&
        !_changeRequest.hasMatch(normalized)) {
      return AgentDecisionRoute.direct;
    }
    // Merely reading production state is not a high-impact operation. Apply
    // the risk escalation after the exact read-only shortcut so topic words
    // do not masquerade as operational impact.
    if (_highRiskRequest.hasMatch(normalized)) {
      return AgentDecisionRoute.deep;
    }
    // An action verb does not prove that a change is bounded or single-path.
    // Leave non-trivial changes to the semantic router instead of treating
    // every "fix" or "implement" request as standard by construction.
    return AgentDecisionRoute.uncertain;
  }

  static bool shouldCritique(String task, AgentDecisionPlan plan) {
    if (isHighRisk(task)) return true;
    final selected = plan.candidates.firstWhere(
      (candidate) => candidate.id == plan.recommendedId,
    );
    return RegExp(
      r'\b(high|critical|irreversible|unknown|unverified)\b|高风险|严重|不可逆|未知|未验证',
      caseSensitive: false,
    ).hasMatch(selected.risk);
  }

  static String compactVerificationEvidence(
    Iterable<String> contents, {
    int maxChars = 6000,
  }) {
    const markers = <String>[
      '[Command executed]',
      '[File written]',
      '[File edited]',
      '[File write failed]',
      '[File edit failed]',
      '[Tool result]',
    ];
    final relevant = contents
        .where((content) => markers.any(content.contains))
        .map(
          (content) => content.length <= 2000
              ? content
              : content.substring(content.length - 2000),
        )
        .join('\n\n');
    if (relevant.length <= maxChars) return relevant;
    return relevant.substring(relevant.length - maxChars);
  }

  static bool hasDeterministicValidationEvidence(
    AgentDecisionPlan plan,
    String evidence,
  ) {
    if (evidence.isEmpty ||
        evidence.contains('[File write failed]') ||
        evidence.contains('[File edit failed]')) {
      return false;
    }
    final exitCodes = RegExp(r'\[exit_code=([^\]]+)\]')
        .allMatches(evidence)
        .map((match) => match.group(1))
        .whereType<String>()
        .toList(growable: false);
    if (exitCodes.any((code) => code != '0')) return false;

    final selected = plan.candidates.firstWhere(
      (candidate) => candidate.id == plan.recommendedId,
    );
    final validation = selected.validation.toLowerCase();
    final normalizedEvidence = evidence.toLowerCase();
    final requiresCommandProof = RegExp(
      r'\b(test|analy[sz]e|build|lint|check|verify)\b|测试|分析|构建|检查|验证',
    ).hasMatch(validation);
    if (requiresCommandProof) {
      return exitCodes.isNotEmpty &&
          (normalizedEvidence.contains('test') ||
              normalizedEvidence.contains('analy') ||
              normalizedEvidence.contains('build') ||
              normalizedEvidence.contains('lint') ||
              normalizedEvidence.contains('check'));
    }
    return exitCodes.isNotEmpty ||
        evidence.contains('[File written]') ||
        evidence.contains('[File edited]');
  }

  static String guideFor(AgentDecisionRoute route) => switch (route) {
    AgentDecisionRoute.direct =>
      'Use direct, verifiable steps. Finish when the evidence is sufficient.',
    AgentDecisionRoute.standard =>
      'Use a short execution plan, then act. Avoid separate alternatives or self-review unless evidence reveals material risk.',
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
