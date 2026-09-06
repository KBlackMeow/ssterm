import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_deliberation.dart';
import 'package:ssterm/services/agent_decision_policy.dart';
import 'package:ssterm/services/llm_service.dart';

void main() {
  test('router request classifies execution mode and accepts fenced JSON', () {
    final request = AgentDeliberation.routeRequest('Assess the change.');

    expect(request.profile.allowedNativeToolNames, isEmpty);
    expect(request.profile.systemPromptOverride, contains('solution workflow'));
    expect(
      AgentDeliberation.parseRoute('''```json
{"route":"deep","confidence":0.86,"signals":["rollback_required"]}
```''')?.route,
      AgentDecisionRoute.deep,
    );
    expect(
      AgentDeliberation.parseRoute(
        '{"route":"standard","confidence":0.7,"signals":[]}',
      )?.confidence,
      0.7,
    );
    expect(
      AgentDeliberation.parseRoute('standard')?.route,
      AgentDecisionRoute.standard,
    );
    expect(
      AgentDeliberation.parseRoute('{"mode":"normal",}')?.route,
      AgentDecisionRoute.standard,
    );
    expect(
      AgentDeliberation.parseRoute('Route: complex')?.route,
      AgentDecisionRoute.deep,
    );
    expect(
      AgentDeliberation.parseRoute(r'{\"route\":\"standard\"}')?.route,
      AgentDecisionRoute.standard,
    );
    expect(AgentDeliberation.parseRoute('{"route":"uncertain"}'), isNull);
  });

  test('planner request is tool-free and asks for comparable candidates', () {
    final request = AgentDeliberation.planRequest('Compare deployment paths.');

    expect(request.profile.allowedNativeToolNames, isEmpty);
    expect(request.profile.systemPromptOverride, contains('exactly 2'));
    expect(request.profile.maxOutputTokens, 384);
    expect(
      request.messages.single.content,
      contains('Compare deployment paths.'),
    );
  });

  test('planner parsing rejects malformed output', () {
    expect(AgentDeliberation.parsePlan('not JSON'), isNull);
    expect(
      AgentDeliberation.parsePlan(
        '{"recommendedId":"a","candidates":[{"id":"a"}]}',
      ),
      isNull,
    );
  });

  test('verifier parses an incomplete result with recovery evidence', () {
    final verdict = AgentDeliberation.parseVerdict(
      '{"complete":false,"evidence":"tests were not run","recovery":"run focused tests"}',
    );

    expect(verdict?.complete, isFalse);
    expect(verdict?.recovery, 'run focused tests');
  });

  test('critic returns only a compact verdict and optional replacement', () {
    final request = AgentDeliberation.critiqueRequest(
      taskContext: 'Choose a deployment.',
      plan: AgentDecisionPlan.tryParseJson('''
{"recommendedId":"a","candidates":[
 {"id":"a","summary":"A","evidence":"some","risk":"high","validation":"test"},
 {"id":"b","summary":"B","evidence":"more","risk":"low","validation":"test"}]}
''')!,
    );
    final verdict = AgentDeliberation.parseCritique(
      '{"accept":false,"issue":"A is unsupported","replacementId":"b"}',
    );

    expect(request.profile.maxOutputTokens, 256);
    expect(request.profile.systemPromptOverride, contains('Do not repeat'));
    expect(verdict?.accept, isFalse);
    expect(verdict?.replacementId, 'b');
  });

  test(
    'planner stream forwards text and parses its final diagnostics',
    () async {
      final chunks = <String>[];
      final updates = <AgentDeliberationStreamUpdate>[];
      final result = await AgentDeliberation.collectPlanStream(
        Stream.fromIterable([
          LlmStreamEvent('reasoning', 'checking alternatives'),
          LlmStreamEvent('text', '{"recommendedId":"a",'),
          LlmStreamEvent(
            'text',
            '"candidates":[{"id":"a","summary":"safe",'
                '"evidence":"proof",'
                '"risk":"small","validation":"test"},{"id":"b",'
                '"summary":"fast","evidence":"proof","risk":"small",'
                '"validation":"test"}]}',
          ),
          LlmStreamEvent.diagnostics(
            malformedEventCount: 0,
            promptTokenCount: 21,
            completionTokenCount: 34,
          ),
        ]),
        chunks.add,
        onUpdate: updates.add,
      );

      expect(chunks, hasLength(2));
      expect(updates, hasLength(3));
      expect(updates.first.isReasoning, isTrue);
      expect(updates.first.content, 'checking alternatives');
      expect(result.value?.recommendedId, 'a');
      expect(result.usage.promptTokenCount, 21);
      expect(result.usage.completionTokenCount, 34);
    },
  );
}
