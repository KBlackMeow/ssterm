# Agent command history implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove the agent-loop cap and write every completed Agent1/Agent2 command result with full output to local JSONL history.

**Architecture:** A focused `CommandExecutionHistory` owns append serialization and best-effort local writes. The host wraps each Agent execution callback after it returns, so both terminal and background paths are recorded without changing executor behavior.

**Tech Stack:** Dart IO, JSON Lines, Flutter tests.

## Global Constraints

- Save complete command output locally; do not silently redact or truncate at the history layer.
- A history write error must not fail, alter, or delay command feedback.
- Record Agent commands only, never manual terminal input.

---

### Task 1: Add JSONL history service

**Files:**
- Create: `lib/services/command_execution_history.dart`
- Create: `test/services/command_execution_history_test.dart`

- [ ] Write a failing test that appends a record to an injected temp file and decodes one JSON line with `command`, `output`, `agentId`, `cwd`, and `exitCode`.
- [ ] Run `flutter test test/services/command_execution_history_test.dart`; expect failure because the service is absent.
- [ ] Implement `CommandExecutionHistory.append(CommandExecutionRecord)` using a per-service Future queue and `File.writeAsString(..., mode: FileMode.append, flush: true)`. Default path is `appDataDir()/logs/agent-command-history.jsonl`.
- [ ] Catch filesystem errors inside `append`, invoke an optional diagnostic callback, and complete normally.
- [ ] Run the test again; expect pass.
- [ ] Commit the service and test.

### Task 2: Record both hosts and remove the loop cap

**Files:**
- Modify: `lib/app/main_ssh.dart`
- Modify: `lib/app/main_views.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify/add: `test/services/command_execution_history_test.dart`

- [ ] Write a failing source-regression assertion that `_maxLoopIterations` and the `max_iterations` stop branch are absent.
- [ ] Run it; expect failure while the cap remains.
- [ ] Delete the loop-cap constant and stop branch; retain history compaction and every other normal stop condition.
- [ ] Create one host helper that records command, completed `CommandResult?`, target kind, cwd, agent id, and cancellation state, then returns the untouched result.
- [ ] Wrap Agent1 and Agent2 `onExecuteAsync` callbacks with that helper. Do not record command-mode fire-and-forget sends.
- [ ] Run `dart format`, targeted tests, `flutter analyze`, `flutter test`, and `git diff --check`.
- [ ] Commit the integration.

