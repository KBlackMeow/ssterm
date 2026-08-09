# Command Purpose Result Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the AI-supplied execution purpose on every command result card.

**Architecture:** Carry an optional `commandPurpose` field through the existing `_ChatMessage.system` data path. Render it in `_CommandResultCard` with a deterministic fallback when the AI did not supply a reason.

**Tech Stack:** Dart 3.11, Flutter, `flutter_test`.

## Global Constraints

- Apply to normal, warning, and dangerous command results.
- Do not alter execution, confirmation, risk classification, or LLM feedback.
- Use `执行目的：AI 未提供` for null or empty values.

---

### Task 1: Carry and render command purpose

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Modify: `lib/widgets/ai_assistant_panel_widgets.dart`
- Test: `test/widgets/agent_panel_layout_invariants_test.dart`

**Interfaces:**
- Produces: `_ChatMessage.system({required String text, required String commandRun, String? commandPurpose, int? commandExitCode, CommandRiskAssessment? commandRisk})`
- Produces: `_CommandResultCard({required String command, required String output, required String? purpose, required int? exitCode, required CommandRiskAssessment? risk})`

- [ ] **Step 1: Write the failing invariant test**

Assert the model declares and stores `commandPurpose`, the loop passes `toolCall.reason`, content forwards `msg.commandPurpose`, and the result card contains both `执行目的：` and `AI 未提供`.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart`

Expected: FAIL because the result message and card do not carry purpose.

- [ ] **Step 3: Implement the minimal data flow**

Add `commandPurpose` to `_ChatMessage`, pass `toolCall.reason` at command completion, forward it into `_CommandResultCard`, normalize null/blank to `AI 未提供`, and render `执行目的：$purpose` below the command header.

- [ ] **Step 4: Verify GREEN and regression suite**

Run: `dart format lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/widgets/agent_panel_layout_invariants_test.dart && flutter test test/widgets/agent_panel_layout_invariants_test.dart && flutter test && git diff --check`

Expected: all tests pass and no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat: show command purpose on result cards"
```
