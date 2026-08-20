# Agent Stop Task Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the first prompt after Stop a new primary Agent task while retaining earlier conversation only as reference.

**Architecture:** `_cancelAgent()` discards queued input and records one transient boundary flag. `_agentRespond()` consumes that flag once and prefixes the new user history item with host-authored instructions that prohibit automatic resumption of the stopped task. `/clear` resets the flag along with the conversation.

**Tech Stack:** Flutter/Dart, `flutter_test`, existing source-level Agent invariants.

## Global Constraints

- Preserve the visible transcript and prior conversation history on Stop.
- Do not change provider protocols, command approval, or background-process cancellation.
- The boundary must apply once: the next prompt only.
- The latest prompt must remain verbatim in the model-bound user content.
- `/clear`, `/reset`, and `/new` must reset the pending boundary.

---

### Task 1: Mark Stop as a one-shot task boundary

**Files:**

- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`

**Interfaces:**

- Consumes: `_cancelAgent()`, `_clearChat()`, `_agentRespond(String userText)`, and `_conversationHistory`.
- Produces: `bool _nextAgentTurnStartsNewTask`, set by Stop and consumed by the next Agent user turn.

- [ ] **Step 1: Write the failing regression tests**

Add these tests to `test/widgets/ai_assistant_panel_selection_test.dart`:

```dart
test('stop discards queued input and marks the next prompt as a new task', () {
  final panel = File('lib/widgets/ai_assistant_panel.dart').readAsStringSync();
  final stop = panel.substring(
    panel.indexOf('void _cancelAgent()'),
    panel.indexOf('void _cancelPendingAgentDecisions()'),
  );

  expect(stop, contains('_pendingUserInput.clear();'));
  expect(stop, contains('_nextAgentTurnStartsNewTask = true;'));
});

test('first prompt after stop carries a one-shot task-boundary instruction', () {
  final loop = File('lib/widgets/ai_assistant_panel_loop.dart').readAsStringSync();

  expect(loop, contains('if (_nextAgentTurnStartsNewTask)'));
  expect(loop, contains('The preceding task was stopped by the user.'));
  expect(loop, contains('The latest user message is the new primary task.'));
  expect(loop, contains('_nextAgentTurnStartsNewTask = false;'));
  expect(loop, contains(r'$taskBoundary$body'));
});

test('clear chat resets a pending stop task boundary', () {
  final panel = File('lib/widgets/ai_assistant_panel.dart').readAsStringSync();
  final clear = panel.substring(
    panel.indexOf('void _clearChat()'),
    panel.indexOf('Future<void> _restoreSession()'),
  );

  expect(clear, contains('_nextAgentTurnStartsNewTask = false;'));
});
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
flutter test test/widgets/ai_assistant_panel_selection_test.dart
```

Expected: FAIL because `_nextAgentTurnStartsNewTask` and the task-boundary content do not exist.

- [ ] **Step 3: Add the minimal task-boundary state and prompt injection**

In `lib/widgets/ai_assistant_panel.dart`, add beside `_pendingUserInput`:

```dart
/// Set by Stop and consumed by the next model-bound user prompt.
/// History remains available for reference, but the preceding task must not
/// resume unless that prompt explicitly requests it.
var _nextAgentTurnStartsNewTask = false;
```

At the start of `_cancelAgent()`, after cancellation has begun and before its tail can call `_drainQueuedUserInput()`, add:

```dart
_pendingUserInput.clear();
_nextAgentTurnStartsNewTask = true;
```

In `_clearChat()`, reset the transient marker before clearing persisted state:

```dart
_nextAgentTurnStartsNewTask = false;
```

In `_agentRespond()` in `lib/widgets/ai_assistant_panel_loop.dart`, consume the marker before adding the user item to `_conversationHistory`:

```dart
final taskBoundary = _nextAgentTurnStartsNewTask
    ? '''<task_boundary>
The preceding task was stopped by the user. Do not resume its plan, commands,
tool calls, or follow-up work unless the latest user message explicitly asks
for it. The latest user message is the new primary task. Earlier conversation
is reference-only: use it only for facts, completed results, or context.
</task_boundary>

'''
    : '';
_nextAgentTurnStartsNewTask = false;
```

Build `body` as today, then prepend the boundary when appending history:

```dart
_conversationHistory.add({'role': 'user', 'content': '$taskBoundary$body'});
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run:

```bash
flutter test test/widgets/ai_assistant_panel_selection_test.dart
```

Expected: PASS.

- [ ] **Step 5: Run formatting, analysis, and the full suite**

Run:

```bash
dart format lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart
flutter analyze
flutter test
```

Expected: formatter makes no further changes after rerun; analysis and all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart
git commit -m "fix(agent): make stop start a new task boundary"
```
