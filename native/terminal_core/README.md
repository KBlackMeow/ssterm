# SSTerm terminal core

`terminal_core` is the Rust-owned hot path for terminal byte parsing and
screen-cell mutation. Flutter continues to own painting, input gestures and
application state. The C ABI is deliberately batch oriented: one call feeds a
PTY chunk and reports a dirty-row range, so no per-cell FFI callbacks occur.

## Build and test

```sh
cargo test --manifest-path native/terminal_core/Cargo.toml
cargo build --manifest-path native/terminal_core/Cargo.toml --release
# Or run the complete Rust + Dart FFI gate from the repository root:
sh tool/test_rust_terminal_core.sh
```

Measure the release parser/buffer hot path with:

```sh
cargo run --manifest-path native/terminal_core/Cargo.toml --release --example throughput
```

## Production-stream shadow mode

The xterm renderer remains authoritative while VT feature parity is expanded.
On desktop, set the following before launching SSTerm to feed every local PTY
output chunk into this native core as well as xterm:

```sh
SSTERM_RUST_TERMINAL_CORE=1 flutter run -d macos
```

This mode exercises the deployed FFI parser, resizing, ownership, and teardown
against real shell output without changing what users see. It is deliberately
opt-in because it performs both parsers' work; it is a compatibility gate, not
the final rendering-performance mode.

The ABI contract is in `include/ssterm_terminal_core.h`. Its tests cover
incremental UTF-8, split terminal control sequences, OSC 7 cwd notifications,
scrolling, bounded scrollback, resizing, SGR cell styles, and row snapshots.

This ABI supports the common terminal data path: printable UTF-8, C0 controls,
cursor/erase/character and line-edit CSI, scrolling regions, standard SGR
attributes and colors, OSC title/cwd, DEC alternate buffers, cells, and bounded
scrollback. Selection, reflow, and the remaining VT mode surface stay on the
Dart engine until their fixture parity suite is complete; the application must
not switch its default terminal engine before that gate passes.
