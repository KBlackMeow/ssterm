# Terminal Performance Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SSTerm's terminal output path fast, observable, and regression-resistant after the initial PTY flow-control fix.

**Architecture:** Keep the current `OutputPipe` queue/backpressure design as the ingestion boundary, then add observability and rendering-side improvements in small, independently testable slices. Prioritize tests and benchmarks around real user symptoms: large output floods, alternate-buffer scrolling, first-frame correctness, and scrollback memory pressure.

**Tech Stack:** Dart, Flutter, `package:test`/`flutter_test`, local `packages/xterm`, local `packages/flutter_pty`.

## Global Constraints

- Preserve current PTY backpressure behavior: native reads are acknowledged when bytes are accepted into the bounded queue, not when rendered.
- Do not call `Terminal.write()` synchronously from render/layout callbacks.
- Keep `less`, `vim`, `htop`, and main-buffer history scrolling behavior distinct.
- Add tests before behavior changes.
- Prefer focused commits per task.

---

## File Structure

- Modify: `lib/io/output_pipe.dart`
  - Owns byte ingestion, queue watermarks, UTF-8 decoding, OSC 133 capture, and PTY acceptance callbacks.
- Create: `lib/io/output_pipe_metrics.dart`
  - Small immutable metrics snapshot for debug UI/tests without exposing internal buffers.
- Modify: `test/io/output_pipe_test.dart`
  - Regression tests for accepted bytes, queue watermarks, UTF-8 boundaries, and metrics.
- Modify: `packages/xterm/lib/src/terminal.dart`
  - Candidate location for dirty-row tracking hooks if the existing model exposes row mutation points there.
- Modify: `packages/xterm/lib/src/buffer/*.dart`
  - Candidate location for dirty-row flags if row mutations are lower-level than `Terminal`.
- Modify: `packages/xterm/lib/src/ui/terminal_view.dart` or `packages/xterm/lib/src/ui/render_terminal.dart`
  - Candidate repaint boundary for rendering only dirty rows.
- Modify: `packages/xterm/test/src/terminal_view_test.dart`
  - Widget regressions for alt-buffer scroll and repaint behavior.
- Create: `test/perf/terminal_output_perf_test.dart`
  - Non-flaky benchmark-style guard for gross regressions, skipped by default unless `SSTERM_RUN_PERF=1`.
- Create: `docs/terminal-performance.md`
  - Records expected behavior, manual QA checklist, and benchmark numbers.

---

### Task 1: Add OutputPipe Observability

**Files:**
- Create: `lib/io/output_pipe_metrics.dart`
- Modify: `lib/io/output_pipe.dart`
- Test: `test/io/output_pipe_test.dart`

**Interfaces:**
- Produces: `OutputPipeMetrics` with `queuedBytes`, `streamsPaused`, `pendingAcceptedBytes`, `holdOutputUntilRelease`.
- Produces: `OutputPipe.metrics` getter.

- [ ] **Step 1: Write the failing metrics test**

Add this test to `test/io/output_pipe_test.dart` inside `group('OutputPipe', ...)`:

```dart
test('metrics expose queue and backpressure state', () {
  fakeAsync((fake) {
    final terminal = Terminal();
    final pipe = OutputPipe(
      terminal,
      holdOutputUntilRelease: true,
      queueHighWatermarkBytes: 10,
      queueLowWatermarkBytes: 4,
    );
    final ctrl = StreamController<List<int>>();
    pipe.bind(ctrl.stream);

    ctrl.add(List.filled(12, 65));
    fake.flushMicrotasks();

    expect(pipe.metrics.queuedBytes, 12);
    expect(pipe.metrics.streamsPaused, isTrue);
    expect(pipe.metrics.pendingAcceptedBytes, 12);
    expect(pipe.metrics.holdOutputUntilRelease, isTrue);

    pipe.dispose();
    ctrl.close();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
flutter test test/io/output_pipe_test.dart --plain-name "metrics expose queue and backpressure state"
```

Expected: FAIL because `OutputPipe.metrics` and `OutputPipeMetrics` do not exist.

- [ ] **Step 3: Add the metrics value object**

Create `lib/io/output_pipe_metrics.dart`:

```dart
class OutputPipeMetrics {
  const OutputPipeMetrics({
    required this.queuedBytes,
    required this.streamsPaused,
    required this.pendingAcceptedBytes,
    required this.holdOutputUntilRelease,
  });

  final int queuedBytes;
  final bool streamsPaused;
  final int pendingAcceptedBytes;
  final bool holdOutputUntilRelease;
}
```

- [ ] **Step 4: Expose metrics from OutputPipe**

In `lib/io/output_pipe.dart`, import the new file and add this getter inside `class OutputPipe`:

```dart
OutputPipeMetrics get metrics => OutputPipeMetrics(
  queuedBytes: _buf.length,
  streamsPaused: _streamsPaused,
  pendingAcceptedBytes: _pendingAcceptedBytes,
  holdOutputUntilRelease: holdOutputUntilRelease,
);
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
flutter test test/io/output_pipe_test.dart --plain-name "metrics expose queue and backpressure state"
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/io/output_pipe.dart lib/io/output_pipe_metrics.dart test/io/output_pipe_test.dart
git commit -m "Add output pipe metrics"
```

---

### Task 2: Add a Manual-Triggered Throughput Guard

**Files:**
- Create: `test/perf/terminal_output_perf_test.dart`
- Modify: `docs/terminal-performance.md`

**Interfaces:**
- Consumes: `OutputPipe`, `Terminal`.
- Produces: a skipped-by-default perf guard runnable with `SSTERM_RUN_PERF=1 flutter test test/perf/terminal_output_perf_test.dart`.

- [ ] **Step 1: Write the perf guard**

Create `test/perf/terminal_output_perf_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:xterm/xterm.dart';

void main() {
  final runPerf = Platform.environment['SSTERM_RUN_PERF'] == '1';

  test(
    'large output flood drains without pathological delay',
    () async {
      final terminal = Terminal(maxLines: 400000);
      final accepted = <int>[];
      final pipe = OutputPipe(
        terminal,
        onBytesAccepted: accepted.add,
      );
      final ctrl = StreamController<List<int>>();
      pipe.bind(ctrl.stream);

      final payload = utf8.encode(
        List.generate(300000, (i) => '${i + 1}').join('\n'),
      );

      final watch = Stopwatch()..start();
      ctrl.add(payload);
      await Future<void>.delayed(const Duration(seconds: 2));
      watch.stop();

      expect(accepted.fold<int>(0, (sum, value) => sum + value), payload.length);
      expect(terminal.buffer.lines.length, greaterThan(1000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));

      pipe.dispose();
      await ctrl.close();
    },
    skip: runPerf ? false : 'Set SSTERM_RUN_PERF=1 to run perf guard.',
  );
}
```

- [ ] **Step 2: Run skipped default test**

Run:

```bash
flutter test test/perf/terminal_output_perf_test.dart
```

Expected: PASS with the test skipped.

- [ ] **Step 3: Run enabled perf guard**

Run:

```bash
SSTERM_RUN_PERF=1 flutter test test/perf/terminal_output_perf_test.dart
```

Expected: PASS locally. If it fails on a slow machine, record the observed time before changing thresholds.

- [ ] **Step 4: Document the command and manual baseline**

Create `docs/terminal-performance.md`:

```markdown
# Terminal Performance

## Regression Commands

- Unit/output pipe: `flutter test test/io/output_pipe_test.dart`
- xterm scroll: `cd packages/xterm && flutter test test/src/terminal_view_test.dart --plain-name "trackpad scroll simulates arrow keys without mouse reporting"`
- Perf guard: `SSTERM_RUN_PERF=1 flutter test test/perf/terminal_output_perf_test.dart`

## Manual QA

- `seq 1 300000` should stream quickly without freezing input.
- `less ~/.zshrc` should scroll in the alternate buffer and quit with `q`.
- After quitting `less`, normal terminal history should scroll.
- `vim`, `nvim`, and `htop` should keep receiving scroll inside the app.

## Baseline

Record local machine, date, and observed `seq 1 300000` behavior before changing terminal rendering internals.
```

- [ ] **Step 5: Commit**

```bash
git add test/perf/terminal_output_perf_test.dart docs/terminal-performance.md
git commit -m "Add terminal throughput guard"
```

---

### Task 3: Prototype Dirty-Row Rendering Behind a Flag

**Files:**
- Modify: `packages/xterm/lib/src/terminal.dart`
- Modify: `packages/xterm/lib/src/ui/render_terminal.dart`
- Test: `packages/xterm/test/src/terminal_view_test.dart`

**Interfaces:**
- Produces: internal dirty-row set or range, exposed only inside `packages/xterm`.
- Produces: rendering flag defaulting off until verified.

- [ ] **Step 1: Locate row mutation points**

Run:

```bash
rg "notifyListeners|markNeedsPaint|write\\(|line|buffer" packages/xterm/lib/src
```

Expected: identify the narrowest place where terminal buffer rows are changed before paint.

- [ ] **Step 2: Add a failing repaint scope test**

Add a test in `packages/xterm/test/src/terminal_view_test.dart` that writes one line after initial paint and asserts the render object receives a dirty-row update instead of a full invalidation. Use the actual render object API found in Step 1; if no API exists, add a private test-only debug counter guarded by `assert`.

- [ ] **Step 3: Implement minimal dirty-row tracking**

Add dirty tracking at the mutation point found in Step 1. Keep the first implementation conservative:

```dart
final _dirtyRows = <int>{};

void markRowDirty(int row) {
  if (row < 0) return;
  _dirtyRows.add(row);
}

Set<int> takeDirtyRows() {
  final rows = Set<int>.from(_dirtyRows);
  _dirtyRows.clear();
  return rows;
}
```

- [ ] **Step 4: Keep full repaint fallback**

In the render path, if dirty rows are empty, viewport size changed, font metrics changed, selection changed, cursor changed, or scroll offset changed, keep the existing full repaint path.

- [ ] **Step 5: Run package tests**

Run:

```bash
cd packages/xterm && flutter test test/src/terminal_view_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/xterm/lib/src packages/xterm/test/src/terminal_view_test.dart
git commit -m "Prototype dirty row rendering"
```

---

### Task 4: Harden Scrollback Memory Behavior

**Files:**
- Modify: `packages/xterm/lib/src/buffer/*.dart`
- Test: add or modify the closest existing xterm buffer test under `packages/xterm/test/src/`

**Interfaces:**
- Consumes: existing max-lines / scrollback configuration.
- Produces: tests proving old lines are released when scrollback exceeds configured limits.

- [ ] **Step 1: Find scrollback storage**

Run:

```bash
rg "maxLines|scrollback|List<.*Line|buffer.lines" packages/xterm/lib packages/xterm/test
```

Expected: identify the class that owns retained buffer lines.

- [ ] **Step 2: Add failing retention test**

Add a test that creates a terminal with a small scrollback limit, writes more lines than the limit, and asserts retained line count stays bounded.

- [ ] **Step 3: Fix retention only if test fails**

If the test already passes, keep the test and do not change production code. If it fails, trim retained lines at the buffer owner found in Step 1.

- [ ] **Step 4: Run focused tests**

Run:

```bash
cd packages/xterm && flutter test test/src
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/xterm/lib/src packages/xterm/test/src
git commit -m "Harden terminal scrollback retention"
```

---

### Task 5: Release Readiness Pass

**Files:**
- Modify: `docs/terminal-performance.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: documented release checklist and final verification result.

- [ ] **Step 1: Run automated verification**

Run:

```bash
flutter analyze
flutter test test/io/output_pipe_test.dart test/services/terminal_command_executor_test.dart test/services/command_safety_test.dart test/terminal_cursor_style_test.dart test/models/tab_model_test.dart
cd packages/xterm && flutter test test/src/terminal_view_test.dart
```

Expected: PASS. If full `flutter test` is run from repo root and `test/services/local_pty_env_test.dart` fails due local `PATH`, record it as an environment-sensitive existing test before changing it.

- [ ] **Step 2: Run manual QA**

Run in SSTerm:

```bash
seq 1 300000
less ~/.zshrc
vim ~/.zshrc
htop
```

Expected: large output streams smoothly; `less` scrolls; app scroll stays inside app; normal history scroll works after exiting apps.

- [ ] **Step 3: Record results**

Append to `docs/terminal-performance.md`:

```markdown
## Verification Log

- Date:
- Commit:
- `flutter analyze`:
- Focused tests:
- `seq 1 300000` manual result:
- `less ~/.zshrc` manual result:
- `vim`/`htop` manual result:
```

- [ ] **Step 4: Commit**

```bash
git add docs/terminal-performance.md
git commit -m "Document terminal performance verification"
```

---

## Self-Review

- Spec coverage: covers observability, throughput regression guard, dirty-row rendering, scrollback memory, and release verification.
- Placeholder scan: no TBD/TODO placeholders; Task 3 intentionally requires codebase discovery before touching internals because dirty-row mutation ownership must be confirmed in the local xterm package.
- Type consistency: `OutputPipeMetrics` and `OutputPipe.metrics` are defined in Task 1 and used only after creation.
