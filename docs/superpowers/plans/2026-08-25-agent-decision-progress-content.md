# Adaptive Decision Progress Content Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show user-readable planning and recommendation messages during an adaptive-decision run while retaining the decision card for operational status.

**Architecture:** Add a small pure formatter that turns the already-parsed `AgentDecisionPlan` and `AgentDecisionCandidate` data into safe transcript text. The Agent loop appends those strings as ordinary assistant messages after planning and review respectively; it continues to append the existing streamed execution message unchanged. The card remains client-only telemetry and carries no user-facing decision body.

**Tech Stack:** Flutter/Dart, `flutter_test`, existing Agent decision policy and transcript model.

## Global Constraints

- Never expose raw planner output, internal prompts, or hidden chain-of-thought.
- Use only structured fields already parsed into `AgentDecisionPlan`.
- Do not add these client-only progress messages to `_conversationHistory`.
- Preserve the standard execution fallback when planning cannot produce a valid plan.

---

### Task 1: Pure decision-progress transcript formatter

**Files:**
- Create: `lib/services/agent_decision_transcript.dart`
- Create: `test/services/agent_decision_transcript_test.dart`

**Interfaces:**
- Consumes: `AgentDecisionPlan` and `AgentDecisionCandidate` from `lib/services/agent_decision_policy.dart`.
- Produces: `AgentDecisionTranscript.planning(AgentDecisionPlan)` and `AgentDecisionTranscript.recommendation(AgentDecisionPlan)` returning ordinary Markdown text.

- [ ] **Step 1: Write the failing tests**

```dart
test('planning formats each parsed candidate without raw JSON', () {
  final text = AgentDecisionTranscript.planning(plan);

  expect(text, contains('已完成方案梳理'));
  expect(text, contains('方案 a：稳妥方案'));
  expect(text, contains('方案 b：快速方案'));
  expect(text, isNot(contains('recommendedId')));
});

test('recommendation identifies the selected candidate and validation', () {
  final text = AgentDecisionTranscript.recommendation(plan);

  expect(text, contains('建议采用：稳妥方案'));
  expect(text, contains('验证方式：运行检查'));
});
```

- [ ] **Step 2: Run the formatter tests to verify they fail**

Run: `flutter test test/services/agent_decision_transcript_test.dart`

Expected: FAIL because `agent_decision_transcript.dart` and `AgentDecisionTranscript` do not exist.

- [ ] **Step 3: Implement the formatter**

```dart
abstract final class AgentDecisionTranscript {
  static String planning(AgentDecisionPlan plan) => [
    '已完成方案梳理：',
    for (final candidate in plan.candidates)
      '- 方案 ${candidate.id}：${candidate.summary}\n  适用性：${candidate.fit}\n  风险：${candidate.risk}',
  ].join('\n');

  static String recommendation(AgentDecisionPlan plan) {
    final candidate = plan.candidates.firstWhere(
      (item) => item.id == plan.recommendedId,
    );
    return '建议采用：${candidate.summary}\n'
        '依据：${candidate.evidence}\n'
        '验证方式：${candidate.validation}';
  }
}
```

- [ ] **Step 4: Run formatter tests to verify they pass**

Run: `flutter test test/services/agent_decision_transcript_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit the formatter and its tests**

```bash
git add lib/services/agent_decision_transcript.dart test/services/agent_decision_transcript_test.dart
git commit -m "feat(agent): format decision progress for transcript"
```

### Task 2: Append decision progress to the visible transcript

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart:112-220`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart:20-70`

**Interfaces:**
- Consumes: `AgentDecisionTranscript.planning(plan)` and `AgentDecisionTranscript.recommendation(plan)`.
- Produces: normal `_ChatMessage.ai(text: ...)` messages between the decision card and the existing streamed execution message.

- [ ] **Step 1: Write the failing loop coverage**

```dart
test('deep decisions append readable planning and recommendation messages', () {
  final loop = File('lib/widgets/ai_assistant_panel_loop.dart').readAsStringSync();

  expect(loop, contains('AgentDecisionTranscript.planning(planned)'));
  expect(loop, contains('AgentDecisionTranscript.recommendation(plan)'));
  expect(loop, contains('_messages.add(_ChatMessage.ai(text:'));
});
```

- [ ] **Step 2: Run the loop test to verify it fails**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: FAIL because the loop does not append progress messages yet.

- [ ] **Step 3: Implement the transcript insertion**

```dart
if (planned != null) {
  _messages.add(_ChatMessage.ai(
    text: AgentDecisionTranscript.planning(planned),
  ));
}

if (plan == null) {
  _messages.add(_ChatMessage.ai(
    text: '方案梳理未得到有效结果，已切换为标准执行流程。',
  ));
} else {
  _messages.add(_ChatMessage.ai(
    text: AgentDecisionTranscript.recommendation(plan),
  ));
}
```

Import `../../services/agent_decision_transcript.dart` alongside the loop's existing service imports. Add messages only inside existing `setState` blocks so the transcript immediately rerenders and scrolls through the existing post-update behavior.

- [ ] **Step 4: Run loop coverage and formatter tests**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart test/services/agent_decision_transcript_test.dart`

Expected: PASS.

- [ ] **Step 5: Run full verification and commit**

Run: `dart format lib/services/agent_decision_transcript.dart lib/widgets/ai_assistant_panel_loop.dart test/services/agent_decision_transcript_test.dart test/widgets/ai_assistant_panel_selection_test.dart && flutter analyze lib/services/agent_decision_transcript.dart lib/widgets/ai_assistant_panel_loop.dart && flutter test`

Expected: analyzer reports no issues and all Flutter tests pass.

```bash
git add lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart
git commit -m "feat(agent): show decision progress in transcript"
```
