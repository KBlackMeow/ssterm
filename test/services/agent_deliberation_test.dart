import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_deliberation.dart';
import 'package:ssterm/services/llm_service.dart';

void main() {
  test('planner request is tool-free and asks for comparable candidates', () {
    final request = AgentDeliberation.planRequest('Compare deployment paths.');

    expect(request.profile.allowedNativeToolNames, isEmpty);
    expect(request.profile.systemPromptOverride, contains('2 or 3 candidates'));
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

  test(
    'planner stream forwards text and parses its final diagnostics',
    () async {
      final chunks = <String>[];
      final result = await AgentDeliberation.collectPlanStream(
        Stream.fromIterable([
          LlmStreamEvent('text', '{"recommendedId":"a",'),
          LlmStreamEvent(
            'text',
            '"candidates":[{"id":"a","summary":"safe","fit":"fit",'
                '"evidence":"proof","cost":"low","maintenance":"low",'
                '"risk":"small","validation":"test"},{"id":"b",'
                '"summary":"fast","fit":"fit","evidence":"proof",'
                '"cost":"low","maintenance":"low","risk":"small",'
                '"validation":"test"}]}',
          ),
          LlmStreamEvent.diagnostics(
            malformedEventCount: 0,
            promptTokenCount: 21,
            completionTokenCount: 34,
          ),
        ]),
        chunks.add,
      );

      expect(chunks, hasLength(2));
      expect(result.value?.recommendedId, 'a');
      expect(result.usage.promptTokenCount, 21);
      expect(result.usage.completionTokenCount, 34);
    },
  );
}
