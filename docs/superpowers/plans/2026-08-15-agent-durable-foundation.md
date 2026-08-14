# Agent Durable Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound every Agent run with a deterministic resource budget and preserve its terminal outcome as a structured, model-visible event.

**Architecture:** Add a pure-Dart `AgentExecutionBudget` state machine that accounts for model requests, shell calls, and elapsed time. The panel loop owns one budget per user turn, checks it before side effects, and appends a terminal event to history so later user messages never operate on an orphaned run.

**Tech Stack:** Flutter/Dart, `flutter_test`, existing `AgentConversationHistory` and `AiAssistantOverlay`.

## Global Constraints

- Do not weaken `CommandSafety`, command-risk confirmation, process-tree cancellation, or provider wire compatibility.
- New state is pure-Dart, deterministic with injected clock values, and platform-independent.
- Defaults safely bound work without changing a normal short Agent turn.
- New production code always follows a failing test.

---

### Task 1: Add the pure execution-budget state machine

**Files:**
- Create: `lib/services/agent_execution_budget.dart`
- Create: `test/services/agent_execution_budget_test.dart`

**Interfaces:**
- Produces `AgentExecutionBudget`, `AgentBudgetLimit`, and `AgentBudgetStop`.
- `consumeModelRequest(now)` and `consumeShellCall(now)` return `AgentBudgetStop?` and increment only on success.

- [ ] **Step 1: Write failing budget tests**

````dart
test('stops before a model request once its iteration limit is exhausted', () {
  final budget = AgentExecutionBudget(maxModelRequests: 1);
  expect(budget.consumeModelRequest(DateTime(2026)), isNull);
  expect(budget.consumeModelRequest(DateTime(2026)),
      const AgentBudgetStop(AgentBudgetLimit.modelRequests));
});
````

- [ ] **Step 2: Verify the test fails because the service is missing**

Run: `flutter test test/services/agent_execution_budget_test.dart`

Expected: compilation failure mentioning `AgentExecutionBudget`.

- [ ] **Step 3: Implement the minimal state machine**

````dart
enum AgentBudgetLimit { modelRequests, shellCalls, elapsed }
class AgentBudgetStop { const AgentBudgetStop(this.limit); final AgentBudgetLimit limit; }
class AgentExecutionBudget {
  AgentBudgetStop? consumeModelRequest(DateTime now) { /* check then count */ }
  AgentBudgetStop? consumeShellCall(DateTime now) { /* check then count */ }
}
````

- [ ] **Step 4: Run the focused test and format the new files**

Run: `dart format lib/services/agent_execution_budget.dart test/services/agent_execution_budget_test.dart && flutter test test/services/agent_execution_budget_test.dart`

Expected: all budget tests pass.

- [ ] **Step 5: Commit the standalone budget primitive**

````bash
git add lib/services/agent_execution_budget.dart test/services/agent_execution_budget_test.dart
git commit -m "feat: add agent execution budget"
````

### Task 2: Enforce budget and terminal events in the Agent loop

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- Consumes `AgentExecutionBudget` from Task 1.
- Produces a history message beginning `[Agent run stopped]` with a stable reason.

- [ ] **Step 1: Add a failing assertion for a budget terminal event**

````dart
test('agent loop records a terminal budget event before another model call', () {
  expect(source, contains("'[Agent run stopped]'"));
  expect(source, contains('consumeModelRequest'));
});
````

- [ ] **Step 2: Verify it fails**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: failure because the loop does not use `consumeModelRequest`.

- [ ] **Step 3: Add model and shell budget checks**

````dart
final stop = budget.consumeModelRequest(DateTime.now());
if (stop != null) {
  _recordAgentRunStopped(stop);
  break;
}
````

The recorder adds the same safe text to visible messages and history. Before `onExecuteAsync`, call `consumeShellCall`; do not render or run a command when it returns a stop.

- [ ] **Step 4: Run focused tests**

Run: `flutter test test/services/agent_execution_budget_test.dart test/widgets/ai_assistant_panel_selection_test.dart`

Expected: passing tests.

- [ ] **Step 5: Commit loop integration**

````bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart
git commit -m "feat: bound agent loop execution"
````

### Task 3: Preserve explicit interruption context

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- Produces `[Agent run interrupted]` before a busy run is replaced by a new instruction.

- [ ] **Step 1: Add a failing regression assertion**

````dart
test('new input records an interruption before cancelling a busy agent', () {
  expect(source, contains("'[Agent run interrupted]'"));
});
````

- [ ] **Step 2: Verify it fails**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: failure because interruption is only implicit in `_generation`.

- [ ] **Step 3: Add the idempotent interruption recorder**

````dart
void _recordAgentRunInterrupted() {
  const text = '[Agent run interrupted] A new user instruction replaced the in-flight run.';
  _conversationHistory.add({'role': 'user', 'content': text});
  _messages.add(_ChatMessage.notice(text));
}
````

Call it from `_send` only when `_agentBusy` is true and before `_cancelAgent`.

- [ ] **Step 4: Run focused tests and format**

Run: `dart format lib/widgets/ai_assistant_panel.dart test/widgets/ai_assistant_panel_selection_test.dart && flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: passing tests.

- [ ] **Step 5: Commit interruption continuity**

````bash
git add lib/widgets/ai_assistant_panel.dart test/widgets/ai_assistant_panel_selection_test.dart
git commit -m "feat: retain interrupted agent context"
````

### Task 4: Verify the durable-foundation slice

**Files:**
- Modify: `docs/superpowers/specs/2026-08-15-agent-durable-execution-design.md`

- [ ] **Step 1: Mark delivered design items**

Mark execution-budget and interruption-continuity delivered; leave session persistence, output artifacts, and provider usage for subsequent slices.

- [ ] **Step 2: Run static analysis and all regressions**

Run: `flutter analyze && flutter test`

Expected: analysis exits 0 and all tests pass.

- [ ] **Step 3: Inspect final scope**

Run: `git diff main...HEAD --check && git status --short`

Expected: no whitespace errors and only planned files changed.

- [ ] **Step 4: Commit documentation status**

````bash
git add docs/superpowers/specs/2026-08-15-agent-durable-execution-design.md
git commit -m "docs: record durable agent foundation"
```
