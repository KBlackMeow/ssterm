# Windows PTY Startup Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display actionable Windows PTY startup failures in the affected SSTerm terminal.

**Architecture:** Capture stage-specific native errors at their source and transfer an owned error string with the isolate result. Add redacted launch context in Dart before the existing UI renders the exception.

**Tech Stack:** Dart, Flutter tests, Windows C/Win32 APIs, Dart FFI.

## Global Constraints

- Successful shell startup emits no diagnostic text.
- Never display full command arguments, Base64 payloads, or environment values.
- Failures remain visible in the existing local terminal error surface.

---

### Task 1: Redacted Dart launch context

**Files:**
- Modify: `packages/flutter_pty/lib/flutter_pty.dart`
- Test: `test/services/pty_startup_diagnostics_test.dart`

- [ ] Write tests for executable, cwd, argument count/lengths, and redaction.
- [ ] Run the tests and verify they fail because the formatter is absent.
- [ ] Implement the formatter and attach it to `PtyStartException` failures.
- [ ] Run the focused tests and verify they pass.

### Task 2: Native Windows failure detail and isolate transfer

**Files:**
- Modify: `packages/flutter_pty/src/flutter_pty_win.c`
- Modify: `packages/flutter_pty/lib/flutter_pty.dart`
- Test: `test/services/pty_startup_diagnostics_test.dart`

- [ ] Add failing source assertions for stage, numeric code, system message, and owned isolate transfer.
- [ ] Run the tests and verify the expected assertions fail.
- [ ] Format Win32/HRESULT failures at each native boundary and return the copied text from the worker isolate.
- [ ] Run focused tests, static analysis, and the full Flutter suite.
