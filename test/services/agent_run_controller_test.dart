import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_run_controller.dart';

class _Tools implements AgentToolAdapter {
  _Tools(this.results);
  final Map<String, AgentToolResult> results;
  final List<AgentToolRequest> calls = [];
  @override
  Future<AgentToolResult> execute(AgentToolRequest request) async {
    calls.add(request);
    return results[request.operation] ??
        const AgentToolResult(succeeded: true, summary: 'ok');
  }
}

class _Model implements AgentRunModelAdapter {
  _Model(this.selectedRoute, this.nextPlan);
  final AgentRunRoute selectedRoute;
  final AgentRunPlan nextPlan;
  AgentRunState? routedState;
  @override
  Future<AgentRunPlan> plan(AgentRunState state) async => nextPlan;
  @override
  Future<AgentRunRoute> route(AgentRunState state) async {
    routedState = state;
    return selectedRoute;
  }
}

Future<AgentRunTerminal> _terminal(AgentRunHandle handle) => handle.events
    .where((event) => event is AgentRunTerminal)
    .cast<AgentRunTerminal>()
    .first;

void main() {
  const criterion = AcceptanceCriterion(
    id: 'tests',
    condition: 'Tests pass',
    verificationKind: AgentVerificationKind.command,
  );

  test('probe observation is present before dynamic routing', () async {
    final tools = _Tools({
      'inspect': const AgentToolResult(
        succeeded: true,
        summary: 'pubspec found',
      ),
    });
    final model = _Model(AgentRunRoute.direct, const AgentRunPlan(steps: []));
    final handle =
        EvidenceGroundedAgentRunController(tools: tools, model: model).start(
          const AgentRunRequest(
            task: 'inspect project',
            probe: [
              AgentToolRequest(
                name: 'shell',
                operation: 'inspect',
                kind: AgentOperationKind.readOnly,
              ),
            ],
          ),
        );
    await _terminal(handle);
    expect(model.routedState?.evidence, hasLength(1));
    expect(model.routedState?.evidence.single.summary, 'pubspec found');
  });

  test(
    'unsupported planner facts are rejected while assumptions remain explicit',
    () async {
      final tools = _Tools({
        'inspect': const AgentToolResult(
          succeeded: true,
          summary: 'file exists',
        ),
        'change': const AgentToolResult(
          succeeded: true,
          summary: 'changed',
          assertionPassed: true,
        ),
      });
      final model = _Model(
        AgentRunRoute.standard,
        const AgentRunPlan(
          facts: [
            AgentFact(statement: 'invented', evidenceIds: ['missing']),
          ],
          assumptions: [
            AgentAssumption(
              statement: 'package is installed',
              confirmation: 'run tool',
            ),
          ],
          steps: [
            AgentPlanStep(
              id: 'change',
              intent: 'change',
              operation: AgentOperationKind.mutating,
              tool: 'shell',
              input: null,
              criterionIds: ['tests'],
            ),
          ],
        ),
      );
      final terminal = await _terminal(
        EvidenceGroundedAgentRunController(tools: tools, model: model).start(
          const AgentRunRequest(
            task: 'change',
            probe: [
              AgentToolRequest(
                name: 'shell',
                operation: 'inspect',
                kind: AgentOperationKind.readOnly,
              ),
            ],
            criteria: [criterion],
          ),
        ),
      );
      expect(terminal.state.facts, isEmpty);
      expect(terminal.state.assumptions, hasLength(1));
    },
  );

  test(
    'successful mutation without an exact assertion remains unverified',
    () async {
      final tools = _Tools({
        'change': const AgentToolResult(
          succeeded: true,
          summary: 'exit code 0',
        ),
      });
      final model = _Model(
        AgentRunRoute.standard,
        const AgentRunPlan(
          steps: [
            AgentPlanStep(
              id: 'change',
              intent: 'change',
              operation: AgentOperationKind.mutating,
              tool: 'shell',
              input: null,
              criterionIds: ['tests'],
            ),
          ],
        ),
      );
      final terminal = await _terminal(
        EvidenceGroundedAgentRunController(tools: tools, model: model).start(
          const AgentRunRequest(
            task: 'change',
            probe: [],
            criteria: [criterion],
          ),
        ),
      );
      expect(terminal.outcome, AgentRunOutcome.partial);
      expect(
        terminal.state.criteria.single.status,
        AgentCriterionStatus.unverified,
      );
    },
  );

  test('passed exact assertion permits completion', () async {
    final tools = _Tools({
      'change': const AgentToolResult(
        succeeded: true,
        summary: 'tests passed',
        assertionPassed: true,
      ),
    });
    final model = _Model(
      AgentRunRoute.standard,
      const AgentRunPlan(
        steps: [
          AgentPlanStep(
            id: 'change',
            intent: 'change',
            operation: AgentOperationKind.mutating,
            tool: 'shell',
            input: null,
            criterionIds: ['tests'],
          ),
        ],
      ),
    );
    final terminal = await _terminal(
      EvidenceGroundedAgentRunController(tools: tools, model: model).start(
        const AgentRunRequest(task: 'change', probe: [], criteria: [criterion]),
      ),
    );
    expect(terminal.outcome, AgentRunOutcome.completed);
    expect(terminal.state.criteria.single.status, AgentCriterionStatus.passed);
  });
}
