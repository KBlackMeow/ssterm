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

## Production integration

Rust is the default parser and screen authority for local PTY and SSH sessions.
Flutter's vendored xterm package remains the painter, selection model, and
keyboard/mouse encoder, but it does not parse session output. It receives
packed dirty rows, incremental scrollback rows, cursor/mode metadata, and
terminal query responses from this crate.

For diagnostics only, the old Dart parser can be selected before launch:

```sh
SSTERM_DART_TERMINAL_CORE=1 flutter run -d macos
```

Native output batches are allowed to grow to 1 MB, while screen publication is
still paced by the Flutter output pipe. Large history bursts are coalesced and
rebuilt once after the burst instead of copying the full history every frame.

The ABI contract is in `include/ssterm_terminal_core.h`. Its tests cover
incremental UTF-8, split terminal control sequences, OSC/DCS terminal queries,
input modes, scrolling, bounded incremental scrollback, resizing, SGR cell
styles, and packed row snapshots.

This ABI supports the common terminal data path: printable UTF-8, C0 controls,
cursor/erase/character and line-edit CSI, scrolling regions, standard SGR
attributes and colors, OSC title/cwd, common shell capability probes, DEC
alternate buffers and input modes, cells, and bounded scrollback. Selection and
painting intentionally stay in Flutter; session byte parsing and screen state
do not.
