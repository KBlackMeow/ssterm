import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_decision_policy.dart';
import 'package:ssterm/services/agent_deliberation.dart';

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
}
