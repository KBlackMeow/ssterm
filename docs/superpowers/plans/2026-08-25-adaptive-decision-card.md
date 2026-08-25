# Adaptive Decision Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the lifecycle and outcome of a deep adaptive-decision run as one updating card in the Agent transcript.

**Architecture:** Add a private decision-card payload to the existing `_ChatMessage` union and render it from `_AiPanelContent`. `_AiAssistantOverlayState` creates the client-only message after a user task is deep-routed, updates its mutable payload during planning and verification, and never adds it to `_conversationHistory`.

**Tech Stack:** Flutter, Dart, `flutter_test`.

## Global Constraints

- Only deep-routed tasks create a card; fast-route behavior remains unchanged.
- Keep decision payload client-only; no new model prompt or provider protocol fields.
- Reuse the existing private-message/card rendering conventions.

---

### Task 1: Add decision-card transcript model and renderer

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Test: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- Produces: `_DecisionCardData` with route trigger, lifecycle state, summary, and detail.
- Produces: `_ChatMessage.decisionCard(_DecisionCardData)` for client-only transcript use.

- [ ] **Step 1: Write the failing test**

```dart
test('adaptive decision card is a dedicated transcript message', () {
  final models = File('lib/widgets/ai_assistant_panel_models.dart').readAsStringSync();
  final content = File('lib/widgets/ai_assistant_panel_content.dart').readAsStringSync();
  expect(models, contains('class _DecisionCardData'));
  expect(models, contains('factory _ChatMessage.decisionCard'));
  expect(content, contains('class _DecisionCard'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`
Expected: FAIL because the decision-card model and widget do not exist.

- [ ] **Step 3: Write minimal implementation**

```dart
class _DecisionCardData {
  String stage;
  String? summary;
  String? detail;
  _DecisionCardData({required this.stage, this.summary, this.detail});
}

factory _ChatMessage.decisionCard(_DecisionCardData data) =>
    _ChatMessage._(text: '', isUser: false, decisionCardData: data);
```

Render `_DecisionCard` before ordinary notice/AI bubbles in
`_buildAgentMessage`, with route, stage, optional summary and detail.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`
Expected: PASS.

### Task 2: Connect card lifecycle to deep decision execution

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Test: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- Consumes: `_ChatMessage.decisionCard(_DecisionCardData)`.
- Produces: one updating card for a deep-routed agent turn.

- [ ] **Step 1: Write the failing test**

```dart
test('deep decision run records planning, recommendation, and fallback in its card', () {
  final loop = File('lib/widgets/ai_assistant_panel_loop.dart').readAsStringSync();
  expect(loop, contains('_ChatMessage.decisionCard'));
  expect(loop, contains('Planning options'));
  expect(loop, contains('Standard execution'));
  expect(loop, contains('Recommended:'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`
Expected: FAIL because the loop does not create or update a decision card.

- [ ] **Step 3: Write minimal implementation**

```dart
final decisionCard = _DecisionCardData(
  stage: 'Planning options',
  detail: 'Deep route selected for this request.',
);
_messages.add(_ChatMessage.decisionCard(decisionCard));
```

Update the same payload before critique, after parsed plan selection, on
planning fallback, and after verification. Call `setState` and
`_scrollToBottom()` after each visible update.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`
Expected: PASS.

### Task 3: Verify the focused suite and static analysis

**Files:**
- Test: `test/services/agent_decision_policy_test.dart`
- Test: `test/models/agent_config_test.dart`
- Test: `test/widgets/ai_assistant_panel_selection_test.dart`

- [ ] **Step 1: Run formatter**

Run: `dart format lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart`
Expected: Files are formatted without errors.

- [ ] **Step 2: Run focused regression suite**

Run: `flutter test test/services/agent_decision_policy_test.dart test/models/agent_config_test.dart test/widgets/ai_assistant_panel_selection_test.dart`
Expected: PASS.

- [ ] **Step 3: Run static analysis**

Run: `flutter analyze lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart`
Expected: No issues found.
