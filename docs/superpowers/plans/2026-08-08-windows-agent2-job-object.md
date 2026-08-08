# Windows Agent2 Job Object implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Support Windows Agent2 local execution with tree-safe cancellation.

**Architecture:** Add a small Windows-native FFI library for Job Object ownership and expose a Dart process-lifecycle handle. Windows shell command builders select PowerShell, cmd, Git Bash, or WSL without terminal injection.

**Tech Stack:** Dart FFI, Win32 Job Objects, CMake, Flutter tests.

## Global Constraints

- All Agent2 cancellation must terminate the entire Windows process tree.
- Unsupported shell configuration returns an explicit result; never terminal fallback.
- POSIX implementation remains unchanged.

### Task 1: Native Job Object bridge

**Files:** `packages/flutter_pty/src/flutter_pty.h`, `packages/flutter_pty/src/flutter_pty_win.c`, generated Dart bindings.

- [ ] Add exported create, assign-pid, terminate, close functions around `CreateJobObjectW`, `AssignProcessToJobObject`, and `TerminateJobObject`.
- [ ] Set `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; return native error codes to Dart.
- [ ] Regenerate bindings and add Windows-only native integration coverage.

### Task 2: Windows shell routing

**Files:** `lib/services/background_command_executor.dart`, `test/services/background_command_executor_test.dart`.

- [ ] Add failing command-builder tests for PowerShell `-NoProfile -NonInteractive -Command`, cmd `/d /s /c`, Git Bash `-c`, and WSL `-- sh -lc`.
- [ ] Implement builders and capability diagnostics.
- [ ] Attach every Windows started PID to a Job Object; timeout/cancel terminates it.
- [ ] Run Windows CI/integration tests plus `flutter analyze`.

### Task 3: Host verification

**Files:** `lib/app/main_ssh.dart`, integration tests.

- [ ] Verify Agent2 cancellation leaves visible Windows PTY usable.
- [ ] Verify JSONL retains result data.
- [ ] Commit with `git diff --check`.

