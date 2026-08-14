# Agent Command Observation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Agent command cards live with the newest three output lines, respect transcript scroll position, and use 60-second silence checkpoints for Agent-directed command termination.

**Architecture:** Add a transport-neutral observer to `BackgroundCommandExecutor`; local and SSH commands report a combined, incremental three-line output tail and a silence checkpoint. The panel creates one mutable command card at start, refreshes it from observer events, and asks the model whether to continue or stop when 60 seconds pass without output.

**Tech Stack:** Flutter/Dart, dart:async, dart:io, dartssh2, flutter_test.

## Global Constraints

- Transcript only follows new content when already at the bottom.
- Running cards display exactly three newest logical stdout/stderr lines.
- Output resets the 60-second silence window.
- Only `continueWaiting` continues after silence; missing/invalid/cancelled Agent decisions stop safely.
- Existing safety checks, output cap, total timeout, cancellation and cleanup must remain intact.

---

## File structure

- `lib/services/background_command_executor.dart`: event API, shared line tail, local/SSH silence loop.
- `lib/app/main_ssh.dart`, `lib/app/main_views.dart`: observer forwarding to executors.
- `lib/widgets/ai_assistant_panel.dart`: callback contract and scroll-follow check.
- `lib/widgets/ai_assistant_panel_models.dart`: mutable command card state.
- `lib/widgets/ai_assistant_panel_loop.dart`: live card updates and Agent silence decision.
- `lib/widgets/ai_assistant_panel_widgets.dart`: three-line/running rendering.
- Relevant existing service/widget tests.

### Task 1: Executor output events

**Files:**
- Modify: `lib/services/background_command_executor.dart`
- Test: `test/services/background_command_executor_test.dart`

**Interfaces:**
- Produce:
```dart
sealed class CommandExecutionUpdate {
  const CommandExecutionUpdate(this.elapsed, this.lastThreeLines);
  final Duration elapsed;
  final List<String> lastThreeLines;
}
class CommandOutputUpdate extends CommandExecutionUpdate {
  const CommandOutputUpdate(super.elapsed, super.lastThreeLines);
}
class CommandSilenceCheckpoint extends CommandExecutionUpdate {
  const CommandSilenceCheckpoint(super.elapsed, super.lastThreeLines);
}
enum CommandObservationDecision { continueWaiting, stop }
typedef CommandExecutionObserver = FutureOr<CommandObservationDecision?> Function(
  CommandExecutionUpdate update,
);
```

- [ ] **Step 1: Write failing tests**

```dart
test('reports newest three logical combined output lines', () async {
  final updates = <CommandExecutionUpdate>[];
  await executor.executeLocal(target, 'printf ignored', observer: updates.add);
  expect(updates.whereType<CommandOutputUpdate>().last.lastThreeLines,
      ['two', 'three', 'four']);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/background_command_executor_test.dart`

Expected: fails because `observer` and event types do not exist.

- [ ] **Step 3: Implement minimally**

Add optional `CommandExecutionObserver? observer` to both executor methods. Decode stdout/stderr chunks through one line-tail accumulator, retaining three lines; publish `CommandOutputUpdate` after non-empty chunks. Preserve bounded final output separately.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/services/background_command_executor_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/background_command_executor.dart test/services/background_command_executor_test.dart
git commit -m "feat: report live command output"
```

### Task 2: Silence checkpoint decision

**Files:**
- Modify: `lib/services/background_command_executor.dart`
- Test: `test/services/background_command_executor_test.dart`

**Interfaces:** consume the Task 1 observer; both transports stop through their existing TERM/cancellation paths.

- [ ] **Step 1: Write failing tests**

```dart
test('continues when observer accepts silence checkpoint', () async {
  final result = await executorWithShortSilence.executeLocal(
    target, 'sleep', observer: (_) => CommandObservationDecision.continueWaiting,
  );
  expect(result.cancelled, isFalse);
});
test('stops when observer rejects silence checkpoint', () async {
  final result = await executorWithShortSilence.executeLocal(
    target, 'sleep', observer: (_) => CommandObservationDecision.stop,
  );
  expect(result.cancelled, isTrue);
});
```

Add equivalent SSH fake-session stop coverage.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/background_command_executor_test.dart`

Expected: checkpoint observer is never called.

- [ ] **Step 3: Implement minimally**

Use a 60-second resettable timer (inject a short duration for tests). At expiry publish `CommandSilenceCheckpoint`, await its decision, reset only on `continueWaiting`; null or `stop` terminates. Race with existing total timeout and cancellation.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/services/background_command_executor_test.dart && flutter analyze lib/services/background_command_executor.dart`

Expected: PASS, no diagnostics.

- [ ] **Step 5: Commit**

```bash
git add lib/services/background_command_executor.dart test/services/background_command_executor_test.dart
git commit -m "feat: observe silent agent commands"
```

### Task 3: Forward observer through the application bridge

**Files:**
- Modify: `lib/app/main_ssh.dart:721-771`
- Modify: `lib/app/main_views.dart:413-420`
- Modify: `lib/widgets/ai_assistant_panel.dart:116-122`
- Test: `test/widgets/agent_panel_layout_invariants_test.dart`

- [ ] **Step 1: Write failing invariant**

Assert the overlay callback declares `CommandExecutionObserver? observer`, main views forwards `observer: observer`, and both executor calls receive it.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart`

Expected: FAIL on absent observer contract.

- [ ] **Step 3: Implement minimally**

Widen `onExecuteAsync`, `_recordAgentCommand`, and `_executeAgentCommand`; pass observer unchanged into local/SSH executor calls. Continue persisting only the final `CommandResult`.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart && flutter analyze lib/app/main_ssh.dart lib/app/main_views.dart lib/widgets/ai_assistant_panel.dart`

Expected: PASS, no diagnostics.

- [ ] **Step 5: Commit**

```bash
git add lib/app/main_ssh.dart lib/app/main_views.dart lib/widgets/ai_assistant_panel.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat: wire command observation"
```

### Task 4: Live card and non-intrusive scrolling

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart:399-415`
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart:834-866`
- Modify: `lib/widgets/ai_assistant_panel_widgets.dart:203-305`
- Test: `test/widgets/agent_panel_layout_invariants_test.dart`

- [ ] **Step 1: Write failing invariants**

Assert a named `_isFollowingTranscriptBottom` predicate guards `_scrollToBottom`; assert model/card source contains `lastThreeLines` and a running (`运行中`) label.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart`

Expected: FAIL; cards are currently added only after execution and scrolling is unconditional.

- [ ] **Step 3: Implement minimally**

Create one system command message before awaiting execution. Store mutable `running`, `lastThreeLines`, final output and exit state. Observer updates that message and calls guarded scrolling. The card renders `lastThreeLines.join('\\n')` while running/final and a running badge. Define following as no more than 24 logical pixels from `maxScrollExtent`.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart && flutter analyze lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_widgets.dart`

Expected: PASS, no diagnostics.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_widgets.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat: show live agent command output"
```

### Task 5: Ask Agent to assess silent commands

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/services/command_feedback_formatter.dart` if needed
- Test: `test/services/command_feedback_formatter_test.dart`
- Test: `test/widgets/agent_panel_layout_invariants_test.dart`

- [ ] **Step 1: Write failing checkpoint-format test**

```dart
test('formats silence checkpoint with duration and output tail', () {
  final text = CommandFeedbackFormatter().formatObservationCheckpoint(
    command: 'npm test', elapsed: const Duration(seconds: 60),
    lastThreeLines: const ['building', 'still working', ''],
  );
  expect(text, allOf(contains('60s'), contains('still working'),
      contains('continue_waiting or stop_command')));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/command_feedback_formatter_test.dart test/widgets/agent_panel_layout_invariants_test.dart`

Expected: FAIL; checkpoint prompt and decision mapping are absent.

- [ ] **Step 3: Implement minimally**

For `CommandSilenceCheckpoint`, show a transient checking status and make an Agent-only decision request containing command, elapsed time and identical three-line tail. Map only `continue_waiting` to continue; cancellation/malformed/other replies map to stop. Never run a shell command in this decision request.

- [ ] **Step 4: Verify all behavior**

Run: `flutter test test/services/background_command_executor_test.dart test/services/command_feedback_formatter_test.dart test/widgets/agent_panel_layout_invariants_test.dart && flutter analyze && flutter test`

Expected: all commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel_loop.dart lib/services/command_feedback_formatter.dart test/services/command_feedback_formatter_test.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat: let agent assess silent commands"
git status --short
```

