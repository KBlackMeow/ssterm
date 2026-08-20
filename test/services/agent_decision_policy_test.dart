import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_decision_policy.dart';

const enabled = AgentDecisionSettings(enabled: true);

void main() {
  group('AgentDecisionPolicy', () {
    test('keeps direct read-only requests on the fast path', () {
      expect(
        AgentDecisionPolicy.classify('show the current directory', enabled),
        AgentDecisionRoute.fast,
      );
    });

    test('routes explicit alternatives and recommendations to deep work', () {
      expect(
        AgentDecisionPolicy.classify(
          'Compare two deployment approaches and recommend the safest.',
          enabled,
        ),
        AgentDecisionRoute.deep,
      );
    });

    test('returns fast when adaptive decisions are disabled', () {
      expect(
        AgentDecisionPolicy.classify(
          'Compare two deployment approaches and recommend the safest.',
          const AgentDecisionSettings(enabled: false),
        ),
        AgentDecisionRoute.fast,
      );
    });

    test('deep guide defines scope and convergence anchors', () {
      final guide = AgentDecisionPolicy.guideFor(AgentDecisionRoute.deep);

      expect(guide, contains('architecture, constraints, edge cases'));
      expect(guide, contains('decision or an information need'));
      expect(guide, contains('unguided environment inspection'));
      expect(guide, contains('Recommendation'));
    });
  });

  group('AgentDecisionRun', () {
    test('allows recovery only with unseen evidence within its budget', () {
      final run = AgentDecisionRun.deep(
        const AgentDecisionSettings(enabled: true, maxRecoveryModelRequests: 1),
      );

      expect(run.requestRecovery(evidence: ''), isFalse);
      expect(
        run.requestRecovery(evidence: '[exit_code=1] build failed'),
        isTrue,
      );
      expect(
        run.requestRecovery(evidence: '[exit_code=1] build failed'),
        isFalse,
      );
      expect(
        run.requestRecovery(evidence: '[exit_code=2] test failed'),
        isFalse,
      );
    });
  });

  group('AgentDecisionPlan', () {
    test('accepts two complete candidates with a recommendation', () {
      final plan = AgentDecisionPlan.tryParseJson('''
{"recommendedId":"safe","candidates":[
 {"id":"safe","summary":"Incremental change","risk":"low","validation":"run tests"},
 {"id":"fast","summary":"Direct change","risk":"medium","validation":"smoke test"}]}
''');

      expect(plan?.recommendedId, 'safe');
      expect(plan?.candidates, hasLength(2));
    });

    test('rejects incomplete or uncomparable plans', () {
      expect(
        AgentDecisionPlan.tryParseJson(
          '{"recommendedId":"only","candidates":[{"id":"only"}]}',
        ),
        isNull,
      );
    });
  });
}
