# Agent2 SSH execution implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Execute Agent2 SSH commands in independent non-PTY SSH sessions.

**Architecture:** Extend the background executor with an SSH method that owns only one command session. Host routing selects it for live SSH tabs; existing history wrapping remains unchanged.

**Tech Stack:** Dart, dartssh2, Flutter tests.

## Global Constraints

- Never write Agent2 commands to the visible SSH terminal session.
- Cancel/timeout only the command SSHSession, never shared SSHClient/SFTP.
- Preserve full result output for JSONL history.

---

### Task 1: SSH executor

**Files:**
- Modify: `lib/services/background_command_executor.dart`
- Modify: `test/services/background_command_executor_test.dart`

- [ ] Add a testable `shellQuotePosix(String value)` test for apostrophes and a command builder asserting `cd -- '<cwd>' && <command>`.
- [ ] Run `flutter test test/services/background_command_executor_test.dart`; expect compile failure before API exists.
- [ ] Add `Future<CommandResult> executeSsh(SSHClient client, String cwd, String command, {bool Function()? isCancelled})`; call `client.execute` with no PTY, concurrently drain session stdout/stderr, wait for streams plus `done`, and return formatted output.
- [ ] On cancellation/timeout invoke `session.kill(SSHSignal.term)` and `session.close()`; leave client open.
- [ ] Run targeted tests and format.

### Task 2: Host routing

**Files:**
- Modify: `lib/app/main_ssh.dart`

- [ ] Replace Agent2's SSH unsupported result with `BackgroundCommandExecutor.executeSsh(tab.sshClient!, tab.agent2Cwd ?? '/', command, isCancelled: isCancelled)`.
- [ ] Keep unavailable-client error explicit.
- [ ] Run `flutter analyze`, `flutter test`, and `git diff --check`.
- [ ] Commit the implementation.

