# Command Rejection Stops Agent Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** End the current AI Agent loop when a user rejects a proposed shell command, preventing another LLM request.

**Architecture:** The shell-tool execution loop in `AiAssistantOverlay` owns command confirmation and feedback aggregation. Its rejection branch will become a terminal branch, so it preserves UI/logging but skips feedback history and the next `while` iteration.

**Tech Stack:** Flutter, Dart, flutter_test.

## Global Constraints

- A rejected command must not reach `onExecuteAsync`.
- No remaining shell command in the same reply may run.
- No rejection feedback may be sent back to the LLM.
- Existing cancellation and stale-generation behaviour must remain unchanged.

---

### Task 1: Stop the agent loop after command rejection

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart:780-806`
- Test: `test/widgets/ai_assistant_panel_loop_test.dart`

**Interfaces:**
- Consumes: `_DangerProposal.decision`, `AgentConfig`, and `AiAssistantOverlay.onExecuteAsync`.
- Produces: A terminal rejection path in `_continueAgentLoopBody` that does not reach `_conversationHistory.add`.

- [ ] **Step 1: Write the failing widget regression test**

Create a fake streaming Ollama endpoint that returns one shell command, pump `AiAssistantOverlay` configured for it, reject the displayed command card, then assert the endpoint receives exactly one request and `onExecuteAsync` has not been called.

```dart
expect(llmRequestCount, 1);
expect(executedCommands, isEmpty);
```

- [ ] **Step 2: Run the regression test to verify it fails**

Run: `flutter test test/widgets/ai_assistant_panel_loop_test.dart`

Expected: FAIL because the rejection feedback triggers a second LLM request.

- [ ] **Step 3: Implement the terminal rejection branch**

Replace the rejection branch's continuation with a loop exit after its existing UI state and diagnostic logging:

```dart
if (!approved) {
  // Preserve rejected proposal state and diagnostics above.
  break;
}
```

Remove the now-unreachable rejection feedback/result creation in that branch, leaving feedback aggregation exclusively for executed commands.

- [ ] **Step 4: Run the regression test to verify it passes**

Run: `flutter test test/widgets/ai_assistant_panel_loop_test.dart`

Expected: PASS; exactly one LLM request and zero executions.

- [ ] **Step 5: Run targeted static analysis**

Run: `flutter analyze lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_loop_test.dart`

Expected: exit code 0.

- [ ] **Step 6: Commit the implementation**

```bash
git add lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_loop_test.dart
git commit -m "Stop agent loop after command rejection"
```
