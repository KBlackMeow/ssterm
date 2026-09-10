#!/usr/bin/env sh
# Runs the complete Rust terminal-core gate. Kept separate from `flutter test`
# because Cargo must produce the release dylib that the Dart FFI parity suite
# loads.
set -eu

cd "$(dirname "$0")/.."
cargo fmt --manifest-path native/terminal_core/Cargo.toml -- --check
cargo test --manifest-path native/terminal_core/Cargo.toml
cargo fmt --manifest-path native/pty_core/Cargo.toml -- --check
cargo test --manifest-path native/pty_core/Cargo.toml
cargo build --manifest-path native/terminal_core/Cargo.toml --release
cargo build --manifest-path native/pty_core/Cargo.toml --release
flutter test \
  test/services/rust_terminal_core_test.dart \
  test/services/rust_terminal_bridge_test.dart \
  test/services/remote_cwd_parser_test.dart \
  test/io/output_pipe_test.dart
(cd packages/xterm && flutter test test/src/terminal_test.dart)
