import 'dart:async';

/// The operational state of an Agent run.  This is deliberately independent
/// from the chat widget: a UI only renders [AgentRunEvent]s and forwards user
/// responses to an [AgentRunHandle].
enum AgentRunPhase {
  intake,
  probing,
  routing,
  planning,
  executing,
  verifying,
  waitingForUser,
  terminal,
}

enum AgentRunRoute { direct, standard, deliberative }

enum AgentRunOutcome { completed, partial, blocked, failed, cancelled }

enum AgentCriterionStatus { pending, passed, failed, blocked, unverified }

enum AgentPlanStepStatus { pending, running, passed, failed, skipped, blocked }

enum AgentOperationKind { readOnly, mutating, approvalGated }

enum AgentVerificationKind { assertion, command, query, llm }

class AgentGoal {
  const AgentGoal({required this.originalRequest, required this.outcome});
  final String originalRequest;
  final String outcome;
}

class AgentConstraint {
  const AgentConstraint(this.description);
  final String description;
}

class AcceptanceCriterion {
  const AcceptanceCriterion({
    required this.id,
    required this.condition,
    required this.verificationKind,
    this.commandOrQuery,
    this.required = true,
    this.status = AgentCriterionStatus.pending,
    this.evidenceIds = const [],
  });
  final String id;
  final String condition;
  final AgentVerificationKind verificationKind;
  final String? commandOrQuery;
  final bool required;
  final AgentCriterionStatus status;
  final List<String> evidenceIds;

  AcceptanceCriterion copyWith({
    AgentCriterionStatus? status,
    List<String>? evidenceIds,
  }) => AcceptanceCriterion(
    id: id,
    condition: condition,
    verificationKind: verificationKind,
    commandOrQuery: commandOrQuery,
    required: required,
    status: status ?? this.status,
    evidenceIds: evidenceIds ?? this.evidenceIds,
  );
}

class AgentEvidence {
  const AgentEvidence({
    required this.id,
    required this.timestamp,
    required this.toolName,
    required this.operation,
    required this.kind,
    required this.succeeded,
    required this.summary,
    this.assertionPassed,
    this.truncated = false,
    this.resource,
    this.stepId,
  });
  final String id;
  final DateTime timestamp;
  final String toolName;
  final String operation;
  final AgentOperationKind kind;
  final bool succeeded;
  final String summary;

  /// An adapter-owned exact assertion. A successful operation without this is
  /// evidence of execution only, never proof that a criterion passed.
  final bool? assertionPassed;
  final bool truncated;
  final String? resource;
  final String? stepId;
}

class AgentFact {
  const AgentFact({required this.statement, required this.evidenceIds});
  final String statement;
  final List<String> evidenceIds;
}

class AgentAssumption {
  const AgentAssumption({required this.statement, required this.confirmation});
  final String statement;
  final String confirmation;
}

class AgentPlanStep {
  const AgentPlanStep({
    required this.id,
    required this.intent,
    required this.operation,
    required this.tool,
    required this.input,
    this.dependsOn = const [],
    this.criterionIds = const [],
    this.status = AgentPlanStepStatus.pending,
    this.evidenceIds = const [],
  });
  final String id;
  final String intent;
  final AgentOperationKind operation;
  final String tool;
  final Object? input;
  final List<String> dependsOn;
  final List<String> criterionIds;
  final AgentPlanStepStatus status;
  final List<String> evidenceIds;
  AgentPlanStep copyWith({
    AgentPlanStepStatus? status,
    List<String>? evidenceIds,
  }) => AgentPlanStep(
    id: id,
    intent: intent,
    operation: operation,
    tool: tool,
    input: input,
    dependsOn: dependsOn,
    criterionIds: criterionIds,
    status: status ?? this.status,
    evidenceIds: evidenceIds ?? this.evidenceIds,
  );
}

class AgentRunBudget {
  const AgentRunBudget({
    this.maxToolCalls = 12,
    this.maxReadToolCalls = 8,
    this.maxMutationToolCalls = 4,
    this.maxModelRequests = 8,
    this.maxRecoveryRounds = 1,
    this.maxElapsed = const Duration(minutes: 5),
  });
  final int maxToolCalls,
      maxReadToolCalls,
      maxMutationToolCalls,
      maxModelRequests,
      maxRecoveryRounds;
  final Duration maxElapsed;
}

class AgentRunState {
  const AgentRunState({
    required this.goal,
    required this.constraints,
    required this.criteria,
    required this.facts,
    required this.assumptions,
    required this.steps,
    required this.evidence,
    required this.budget,
    required this.phase,
    required this.route,
    this.failures = const [],
  });
  final AgentGoal goal;
  final List<AgentConstraint> constraints;
  final List<AcceptanceCriterion> criteria;
  final List<AgentFact> facts;
  final List<AgentAssumption> assumptions;
  final List<AgentPlanStep> steps;
  final List<AgentEvidence> evidence;
  final List<String> failures;
  final AgentRunBudget budget;
  final AgentRunPhase phase;
  final AgentRunRoute route;
  AgentRunState copyWith({
    List<AcceptanceCriterion>? criteria,
    List<AgentFact>? facts,
    List<AgentAssumption>? assumptions,
    List<AgentPlanStep>? steps,
    List<AgentEvidence>? evidence,
    List<String>? failures,
    AgentRunPhase? phase,
    AgentRunRoute? route,
  }) => AgentRunState(
    goal: goal,
    constraints: constraints,
    criteria: criteria ?? this.criteria,
    facts: facts ?? this.facts,
    assumptions: assumptions ?? this.assumptions,
    steps: steps ?? this.steps,
    evidence: evidence ?? this.evidence,
    failures: failures ?? this.failures,
    budget: budget,
    phase: phase ?? this.phase,
    route: route ?? this.route,
  );
}

class AgentToolRequest {
  const AgentToolRequest({
    required this.name,
    required this.operation,
    required this.kind,
    this.input,
    this.resource,
    this.stepId,
  });
  final String name, operation;
  final AgentOperationKind kind;
  final Object? input;
  final String? resource, stepId;
}

class AgentToolResult {
  const AgentToolResult({
    required this.succeeded,
    required this.summary,
    this.assertionPassed,
    this.truncated = false,
  });
  final bool succeeded;
  final String summary;

  /// Null means this result made no exact assertion. Success alone is never proof.
  final bool? assertionPassed;
  final bool truncated;
}

abstract interface class AgentToolAdapter {
  Future<AgentToolResult> execute(AgentToolRequest request);
}

abstract interface class AgentApprovalAdapter {
  Future<bool> approve(AgentPlanStep step);
}

abstract interface class AgentClock {
  DateTime now();
}

class SystemAgentClock implements AgentClock {
  const SystemAgentClock();
  @override
  DateTime now() => DateTime.now();
}

/// An optional model adapter. Its output is data; the controller validates it
/// before adding facts or considering a run complete.
abstract interface class AgentRunModelAdapter {
  Future<AgentRunRoute> route(AgentRunState state);
  Future<AgentRunPlan> plan(AgentRunState state);
}

class AgentRunPlan {
  const AgentRunPlan({
    required this.steps,
    this.criteria = const [],
    this.assumptions = const [],
    this.facts = const [],
  });
  final List<AgentPlanStep> steps;
  final List<AcceptanceCriterion> criteria;
  final List<AgentAssumption> assumptions;
  final List<AgentFact> facts;
}

class AgentRunRequest {
  const AgentRunRequest({
    required this.task,
    required this.probe,
    this.criteria = const [],
    this.constraints = const [],
    this.budget = const AgentRunBudget(),
    this.forceRoute,
  });
  final String task;
  final List<AgentToolRequest> probe;
  final List<AcceptanceCriterion> criteria;
  final List<AgentConstraint> constraints;
  final AgentRunBudget budget;
  final AgentRunRoute? forceRoute;
}

sealed class AgentRunEvent {
  const AgentRunEvent();
}

class AgentRunProgress extends AgentRunEvent {
  const AgentRunProgress(this.message, this.state);
  final String message;
  final AgentRunState state;
}

class AgentRunStateChanged extends AgentRunEvent {
  const AgentRunStateChanged(this.state);
  final AgentRunState state;
}

class AgentRunTerminal extends AgentRunEvent {
  const AgentRunTerminal(this.outcome, this.state, {this.blocker});
  final AgentRunOutcome outcome;
  final AgentRunState state;
  final String? blocker;
}

abstract interface class AgentRunHandle {
  Stream<AgentRunEvent> get events;
  Future<void> respond(Object response);
  Future<void> cancel();
}

abstract interface class AgentRunController {
  AgentRunHandle start(AgentRunRequest request);
}

/// Evidence-first controller. The public interface is intentionally only
/// [start] and the returned handle; all phase and recovery ordering remains
/// local to this module.
class EvidenceGroundedAgentRunController implements AgentRunController {
  EvidenceGroundedAgentRunController({
    required this.tools,
    this.model,
    this.approvals,
    this.clock = const SystemAgentClock(),
  });
  final AgentToolAdapter tools;
  final AgentRunModelAdapter? model;
  final AgentApprovalAdapter? approvals;
  final AgentClock clock;
  @override
  AgentRunHandle start(AgentRunRequest request) => _Run(this, request)..start();
}

class _Run implements AgentRunHandle {
  _Run(this.controller, this.request)
    : _started = controller.clock.now(),
      _state = AgentRunState(
        goal: AgentGoal(originalRequest: request.task, outcome: request.task),
        constraints: request.constraints,
        criteria: request.criteria,
        facts: const [],
        assumptions: const [],
        steps: const [],
        evidence: const [],
        budget: request.budget,
        phase: AgentRunPhase.intake,
        route: request.forceRoute ?? AgentRunRoute.standard,
      );
  final EvidenceGroundedAgentRunController controller;
  final AgentRunRequest request;
  final DateTime _started;
  final StreamController<AgentRunEvent> _events = StreamController.broadcast();
  AgentRunState _state;
  bool _cancelled = false;
  int _toolCalls = 0, _readCalls = 0, _mutationCalls = 0;
  @override
  Stream<AgentRunEvent> get events => _events.stream;
  void start() {
    unawaited(_run());
  }

  @override
  Future<void> respond(Object response) async {
    /* Reserved for approval/question adapters. */
  }
  @override
  Future<void> cancel() async {
    _cancelled = true;
  }

  void _emit(String message) {
    _events.add(AgentRunProgress(message, _state));
    _events.add(AgentRunStateChanged(_state));
  }

  Future<void> _run() async {
    _emit('Understanding task');
    if (request.task.trim().isEmpty) {
      return _finish(AgentRunOutcome.blocked, 'No task was supplied.');
    }
    _state = _state.copyWith(phase: AgentRunPhase.probing);
    _emit('Inspecting relevant targets');
    for (final probe in request.probe) {
      if (!await _execute(probe)) return;
    }
    if (_cancelled) return _finish(AgentRunOutcome.cancelled);
    _state = _state.copyWith(phase: AgentRunPhase.routing);
    final route =
        request.forceRoute ??
        (controller.model == null
            ? _defaultRoute()
            : await controller.model!.route(_state));
    _state = _state.copyWith(route: route);
    if (route != AgentRunRoute.direct) {
      _state = _state.copyWith(phase: AgentRunPhase.planning);
      _emit('Planning from observed evidence');
      if (controller.model == null) {
        return _finish(
          AgentRunOutcome.blocked,
          'No planning adapter is available.',
        );
      }
      final plan = await controller.model!.plan(_state);
      final evidenceIds = _state.evidence.map((e) => e.id).toSet();
      final validFacts = plan.facts
          .where(
            (f) =>
                f.evidenceIds.isNotEmpty &&
                f.evidenceIds.every(evidenceIds.contains),
          )
          .toList();
      _state = _state.copyWith(
        steps: plan.steps,
        criteria: [..._state.criteria, ...plan.criteria],
        facts: validFacts,
        assumptions: [..._state.assumptions, ...plan.assumptions],
      );
      _emit('Plan ready: ${plan.steps.length} steps');
    }
    _state = _state.copyWith(phase: AgentRunPhase.executing);
    for (final step in _state.steps) {
      if (_cancelled) return _finish(AgentRunOutcome.cancelled);
      if (!step.dependsOn.every(
        (id) => _state.steps.any(
          (s) => s.id == id && s.status == AgentPlanStepStatus.passed,
        ),
      )) {
        continue;
      }
      if (step.operation == AgentOperationKind.approvalGated &&
          (controller.approvals == null ||
              !await controller.approvals!.approve(step))) {
        _replaceStep(step.copyWith(status: AgentPlanStepStatus.blocked));
        return _finish(
          AgentRunOutcome.blocked,
          'Approval was not granted for ${step.intent}.',
        );
      }
      _replaceStep(step.copyWith(status: AgentPlanStepStatus.running));
      _emit('Running step ${step.id}');
      if (!await _execute(
        AgentToolRequest(
          name: step.tool,
          operation: step.intent,
          kind: step.operation,
          input: step.input,
          stepId: step.id,
        ),
      )) {
        return;
      }
    }
    await _verify();
  }

  AgentRunRoute _defaultRoute() =>
      request.probe.isEmpty ? AgentRunRoute.direct : AgentRunRoute.standard;
  Future<bool> _execute(AgentToolRequest call) async {
    if (_cancelled) {
      await _finish(AgentRunOutcome.cancelled);
      return false;
    }
    if (_overBudget(call.kind)) {
      await _finish(
        AgentRunOutcome.failed,
        'Tool-call budget reached during ${_state.phase.name}.',
      );
      return false;
    }
    final result = await controller.tools.execute(call);
    _toolCalls++;
    if (call.kind == AgentOperationKind.readOnly) {
      _readCalls++;
    } else {
      _mutationCalls++;
    }
    final evidence = AgentEvidence(
      id: 'e${_state.evidence.length + 1}',
      timestamp: controller.clock.now(),
      toolName: call.name,
      operation: call.operation,
      kind: call.kind,
      succeeded: result.succeeded,
      summary: result.summary,
      assertionPassed: result.assertionPassed,
      truncated: result.truncated,
      resource: call.resource,
      stepId: call.stepId,
    );
    _state = _state.copyWith(evidence: [..._state.evidence, evidence]);
    if (call.stepId != null) {
      final step = _state.steps.firstWhere((s) => s.id == call.stepId);
      _replaceStep(
        step.copyWith(
          status: result.succeeded
              ? AgentPlanStepStatus.passed
              : AgentPlanStepStatus.failed,
          evidenceIds: [...step.evidenceIds, evidence.id],
        ),
      );
    }
    _emit(
      result.succeeded
          ? 'Found ${result.summary}'
          : 'Step failed: ${result.summary}',
    );
    return result.succeeded;
  }

  bool _overBudget(AgentOperationKind kind) =>
      _toolCalls >= _state.budget.maxToolCalls ||
      (kind == AgentOperationKind.readOnly
          ? _readCalls >= _state.budget.maxReadToolCalls
          : _mutationCalls >= _state.budget.maxMutationToolCalls) ||
      controller.clock.now().difference(_started) > _state.budget.maxElapsed;
  void _replaceStep(AgentPlanStep replacement) => _state = _state.copyWith(
    steps: [
      for (final s in _state.steps)
        if (s.id == replacement.id) replacement else s,
    ],
  );
  Future<void> _verify() async {
    _state = _state.copyWith(phase: AgentRunPhase.verifying);
    _emit('Verifying acceptance criteria');
    var criteria = _state.criteria;
    for (var i = 0; i < criteria.length; i++) {
      final criterion = criteria[i];
      if (criterion.status != AgentCriterionStatus.pending) continue;
      final matching = _state.evidence
          .where(
            (e) =>
                e.operation == criterion.commandOrQuery ||
                e.stepId != null &&
                    _state.steps.any(
                      (s) =>
                          s.id == e.stepId &&
                          s.criterionIds.contains(criterion.id),
                    ),
          )
          .toList();
      // A success exit/result is deliberately insufficient without an exact assertion.
      final proven = matching.any(
        (e) => e.succeeded && e.assertionPassed == true,
      );
      criteria = [...criteria]
        ..[i] = criterion.copyWith(
          status: proven
              ? AgentCriterionStatus.passed
              : AgentCriterionStatus.unverified,
          evidenceIds: matching.map((e) => e.id).toList(),
        );
      _state = _state.copyWith(criteria: criteria);
      _emit('Criterion ${criterion.id} ${proven ? 'passed' : 'unverified'}');
    }
    final unmet = _state.criteria
        .where((c) => c.required && c.status != AgentCriterionStatus.passed)
        .toList();
    await _finish(
      unmet.isEmpty ? AgentRunOutcome.completed : AgentRunOutcome.partial,
      unmet.isEmpty
          ? null
          : 'Remaining criteria: ${unmet.map((c) => c.id).join(', ')}',
    );
  }

  Future<void> _finish(AgentRunOutcome outcome, [String? blocker]) async {
    if (_state.phase == AgentRunPhase.terminal) return;
    _state = _state.copyWith(phase: AgentRunPhase.terminal);
    _events.add(AgentRunTerminal(outcome, _state, blocker: blocker));
    await _events.close();
  }
}
