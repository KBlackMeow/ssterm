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

## Current Optimization State

- PTY flow control acknowledges bytes when they are accepted into the bounded output queue.
- Output pipe metrics expose queue size, paused state, pending accepted bytes, and first-frame hold state.
- The perf guard is opt-in so normal test runs stay fast.
- Scrollback trimming detaches removed entries so old lines are not retained by the circular buffer owner.
- Dirty rows are tracked on buffer mutation through `Terminal.takeDirtyRows()`. Rendering still uses the existing whole-render-object repaint path; true row-level retained rendering needs a follow-up layer/render split.

## Verification Log

- Date: 2026-07-09
- Commit: `a6c8928`
- `flutter analyze`: PASS
- Focused tests: PASS
  - `flutter test test/io/output_pipe_test.dart test/services/terminal_command_executor_test.dart test/services/command_safety_test.dart test/terminal_cursor_style_test.dart test/models/tab_model_test.dart`
  - `cd packages/xterm && flutter test test/src/terminal_test.dart test/src/utils/circular_buffer_test.dart test/src/core/buffer/buffer_test.dart test/src/core/reflow_test.dart`
  - `cd packages/xterm && flutter test test/src/terminal_view_test.dart --plain-name "trackpad scroll simulates arrow keys without mouse reporting"`
- Perf guard: PASS with `SSTERM_RUN_PERF=1 flutter test test/perf/terminal_output_perf_test.dart`
- Manual `seq 1 300000`: not run in this automated pass
- Manual `less ~/.zshrc`: not run in this automated pass
- Manual `vim`/`htop`: not run in this automated pass
