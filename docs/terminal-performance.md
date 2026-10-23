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
- Dirty rows are tracked on buffer mutation through `Terminal.takeDirtyRows()`.
- Terminal rows now retain their own composited picture layers. Scrolling repositions cached layers; newly exposed rows are recorded once. Cached pictures are validated against their packed cell contents, including colors, attributes, and erased cells; unchanged rows survive terminal output. The cache clears on theme, font, or viewport size changes. The layer cache is capped at 192 rows.
- Main-buffer history scrolling does not send caret geometry updates to the platform text input client unless an IME is composing. A newly focused client and active composition still receive an update. Equal terminal themes compare by color values so rebuilding an unchanged surface keeps its row layers.
- Long, unstyled ASCII rows are painted as one paragraph. Short rows, styled text, and wide glyphs retain cell-by-cell painting.

## Incremental render snapshots (2026-10-24)

Rust now keeps per-row render revisions across `feed` calls. Every retained
snapshot has its own acknowledged revisions, so skipped publications and multiple
consumers do not lose pending changes. The incremental ABI repacks changed rows
into a complete retained grid; the original full-snapshot ABI remains available
as the comparison oracle and fallback for older bundled native libraries.
Resizing, allocation growth, switching snapshot sources, and reuse for history
capture force a complete refresh where needed.

The Flutter bridge still imports the complete authoritative grid. It compares
packed rows before copying, and the painter validates each retained picture
against an exact copy of its cells. This deliberately avoids relying on a
consumed dirty-row set or mutable line identity. Both native imports and Dart
parser mutations are covered. Picture validation costs a linear cell comparison
and retains up to 192 rows of extra cell data (20 bytes per cell); it saves
paragraph/picture recording for unchanged rows.

Verification:

- Native incremental state is compared with full rebuilding across fragmented
  UTF-8/ANSI, skipped publications, and 1024 deterministic mixed operations.
- Every split of a synchronized redraw is checked against the full native grid.
- Widget tests check zero new pictures for identical output or cursor-only
  movement, one new picture for a single changed row or color, and pixel equality
  between cached output and a newly created renderer after erase/replacement.
- The mixed-operation test also exposed two existing edge cases: alternate-screen
  height shrink could overrun the new grid, and clearing an already active
  alternate screen did not mark its cells dirty. Both have regression coverage.

Run `SSTERM_RUN_PERF=1 flutter test test/perf/terminal_output_perf_test.dart`
for the snapshot microbenchmark and existing output-flood guards. On the local
machine, 2000 single-row updates at 240x80 took about 2.5 ms cumulatively in
incremental snapshot capture versus 64 ms in full capture. These are snapshot
measurements in a Flutter test using the release native library, not end-to-end
frame-rate measurements.

The 16 ms output timer is unchanged. Frame-aligned publication is a separate
experiment requiring live input-latency and macOS presentation measurements;
the full-screen compositor observations below do not establish that this timer
is the bottleneck.

## Full-screen history scroll verification (2026-10-17)

On macOS in a profile build with a full-screen terminal and wallpaper enabled, repeated upward scrolling through `ifconfig` output took about 20–22 ms per frame before the paragraph change. The same interaction after the change took about 3–6 ms per frame. This measures Flutter build plus raster time on the local machine, not a universal frame-rate guarantee. The widget golden `long ASCII history stays aligned while scrolling` covers the optimized visual path; existing htop, color, and text-scaling goldens cover its fallbacks.

With retained row layers added, the same full-screen `ifconfig` scroll in a profile build showed roughly 0.5–4 ms build-plus-raster frames during repeated scrolling on this machine. The widget regression test `scrolling cached history reuses painted rows` checks that moving through cached history does not repaint its text, while theme changes and new output do record fresh rows.

In a macOS system full-screen debug build with `ifconfig` history, the user reported that continuous two-finger scrolling was smooth after the caret-update and theme-equality changes. The trackpad widget test verifies sub-line movement and no caret geometry notifications during ordinary history scrolling; the SSTerm surface test verifies that rebuilding unchanged settings retains row layers.

Further full-screen testing showed that the improvement above did not fully resolve dropped frames. A minimal `ListView` stayed smooth, while a minimal `TerminalView` stuttered in full screen even with text drawing disabled. Removing the terminal's active macOS text input connection made scrolling smooth. The fix now hides the native text input view while main-buffer history moves and restores it 150 ms after scrolling stops. It keeps the input client attached and leaves the view visible during IME composition. In the full SSTerm app, the user confirmed smooth full-screen `ifconfig` scrolling and normal shell input afterward. Switching between Skia and Impeller, disabling wallpaper and transparency, and bypassing retained row layers did not resolve this specific stutter.

## Full-screen continuous output (2026-10-17)

The history-scroll fix above did not resolve `time seq 1 2000000`. In a profile build on a 120 Hz MacBook Pro display, output remained visibly jerky only in macOS system full screen with the title bar hidden. Revealing the title bar made the same stream smooth; hiding it again brought the jank back. A system notification also made it smooth. A maximized ordinary window stayed smooth.

Diagnostic frame timings during continuous output were about 54–60 Flutter frames per second in both title-bar states. The 95th percentile build and raster times were generally around 1–3 ms. Output batches took under 1 ms on average. The window and content geometry did not change as the title bar appeared. Shortening the output batch timer from 16 to 8 ms, changing `NSWindow.isOpaque`, marking the root `CALayer` opaque, and adding a tiny native child panel did not remove the state-dependent jank.

The evidence places this remaining issue in the macOS full-screen presentation/compositing path after Flutter rasterization. An `NSWindow.alphaValue` of `0.999` only while in system full screen made continuous output smooth with the title bar both hidden and shown in the user's A/B test. It returns to `1` on exit. This is a compositor workaround; the exact private WindowServer optimization responsible has not been established. The earlier native text-input workaround remains relevant to history scrolling.

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
