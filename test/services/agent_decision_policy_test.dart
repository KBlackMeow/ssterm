import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_decision_policy.dart';

const enabled = AgentDecisionSettings(enabled: true);

void main() {
  group('AgentDecisionPolicy', () {
    test('keeps direct read-only requests on the fast path', () {
      expect(
        AgentDecisionPolicy.classify('show the current directory', enabled),
        AgentDecisionRoute.direct,
      );
    });

    test('routes explicit depth requests directly to deep work', () {
      expect(
        AgentDecisionPolicy.classify(
          'Compare two deployment approaches with deep analysis.',
          enabled,
        ),
        AgentDecisionRoute.deep,
      );
    });

    test('routes material option comparisons directly to deep work', () {
      expect(
        AgentDecisionPolicy.classify(
          'Compare two deployment approaches and recommend the safest.',
          enabled,
        ),
        AgentDecisionRoute.deep,
      );
    });

    test('leaves apparent single-path changes to the semantic router', () {
      expect(
        AgentDecisionPolicy.classify('Fix the failing parser test.', enabled),
        AgentDecisionRoute.uncertain,
      );
    });

    test('risk and comparison signals outrank read-only surface verbs', () {
      expect(
        AgentDecisionPolicy.classify(
          'Show architecture trade-offs for the database migration.',
          enabled,
        ),
        AgentDecisionRoute.deep,
      );
      expect(
        AgentDecisionPolicy.classify(
          'List rollback options for production.',
          enabled,
        ),
        AgentDecisionRoute.deep,
      );
    });

    test('read-only production queries remain direct', () {
      expect(
        AgentDecisionPolicy.classify('show production status', enabled),
        AgentDecisionRoute.direct,
      );
    });

    test('returns fast when adaptive decisions are disabled', () {
      expect(
        AgentDecisionPolicy.classify(
          'Compare two deployment approaches with deep analysis.',
          const AgentDecisionSettings(enabled: false),
        ),
        AgentDecisionRoute.direct,
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
    test('defaults to enough calls for planning and normal execution', () {
      const settings = AgentDecisionSettings(enabled: true);

      expect(settings.maxExecutionModelRequests, 8);
      expect(settings.maxDecisionModelRequests, 2);
      expect(settings.maxRecoveryRounds, 1);
      expect(settings.toJson(), {'enabled': true});
    });

    test('allows recovery only with unseen evidence within its budget', () {
      final run = AgentDecisionRun.deep(
        const AgentDecisionSettings(enabled: true, maxRecoveryRounds: 1),
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

    test(
      'caps deep-model requests and clears focused tools after evidence',
      () {
        final run = AgentDecisionRun.deep(
          const AgentDecisionSettings(
            enabled: true,
            maxExecutionModelRequests: 2,
          ),
        );

        expect(run.firstToolFocusPending, isTrue);
        run.markFirstToolResult();
        expect(run.firstToolFocusPending, isFalse);
        expect(run.consumeExecutionRequest(), isTrue);
        expect(run.consumeExecutionRequest(), isTrue);
        expect(run.consumeExecutionRequest(), isFalse);
      },
    );

    test('keeps decision and execution budgets independent', () {
      final run = AgentDecisionRun.deep(
        const AgentDecisionSettings(
          enabled: true,
          maxExecutionModelRequests: 1,
          maxDecisionModelRequests: 2,
        ),
      );

      expect(run.consumeDecisionRequest(), isTrue);
      expect(run.consumeDecisionRequest(), isTrue);
      expect(run.consumeDecisionRequest(), isFalse);
      expect(run.consumeExecutionRequest(), isTrue);
    });

    test('high-risk review gets one extra decision request only', () {
      final run = AgentDecisionRun.deep(
        const AgentDecisionSettings(enabled: true),
        highRisk: true,
      );

      expect(run.consumeDecisionRequest(), isTrue);
      expect(run.consumeDecisionRequest(), isTrue);
      expect(run.consumeDecisionRequest(), isTrue);
      expect(run.consumeDecisionRequest(), isFalse);
    });
  });

  group('AgentDecisionPlan', () {
    test('accepts two complete candidates with a recommendation', () {
      final plan = AgentDecisionPlan.tryParseJson('''
{"recommendedId":"safe","candidates":[
 {"id":"safe","summary":"Incremental change","evidence":"existing tests","risk":"low","validation":"run tests"},
 {"id":"fast","summary":"Direct change","evidence":"limited","risk":"medium","validation":"smoke test"}]}
''');

      expect(plan?.recommendedId, 'safe');
      expect(plan?.candidates, hasLength(2));
      expect(plan?.withRecommendedId('fast').recommendedId, 'fast');
      expect(plan?.withRecommendedId('missing').recommendedId, 'safe');
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

  group('verification evidence', () {
    final plan = AgentDecisionPlan.tryParseJson('''
{"recommendedId":"safe","candidates":[
 {"id":"safe","summary":"Incremental change","evidence":"tests","risk":"low","validation":"run tests"},
 {"id":"other","summary":"Rewrite","evidence":"none","risk":"high","validation":"run tests"}]}
''')!;

    test(
      'accepts successful matching command evidence without a model call',
      () {
        const evidence = '[Command executed]\n\$ flutter test\n[exit_code=0]';
        expect(
          AgentDecisionPolicy.hasDeterministicValidationEvidence(
            plan,
            evidence,
          ),
          isTrue,
        );
      },
    );

    test('rejects failed command evidence', () {
      const evidence = '[Command executed]\n\$ flutter test\n[exit_code=1]';
      expect(
        AgentDecisionPolicy.hasDeterministicValidationEvidence(plan, evidence),
        isFalse,
      );
    });
  });
}
