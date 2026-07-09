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
