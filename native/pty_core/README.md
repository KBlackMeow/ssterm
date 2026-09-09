# SSTerm PTY core

`pty_core` owns the portable native PTY session lifecycle: process creation,
reader/writer handles, resize, child exit observation, and termination. It is
implemented with `portable-pty`, which uses Unix PTYs on macOS/Linux and
ConPTY on supported Windows systems.

The existing Flutter plugin remains the Dart-port bridge while this core gains
parity. Its public Rust API is deliberately synchronous at the handle level;
the bridge owns the blocking reader and exit-wait threads, preserving the
current `Stream<Uint8List>` Dart contract.

The C ABI in `include/ssterm_pty_core.h` supports argv, working directory,
`KEY=VALUE` environment entries, blocking reads, writes, resize, process ID,
termination, and exit observation. The ABI contract test runs a real shell and
asserts PTY I/O, resize, exit status, and environment forwarding.

## Desktop opt-in

On macOS and Linux, the existing `flutter_pty` Dart API uses this core by
default without changing application code. Keep it enabled explicitly when
launching from tooling if desired:

```sh
SSTERM_USE_RUST_PTY=1 flutter run -d macos
```

The same environment variable works when invoking the bundled desktop
executable directly. To force the legacy C implementation during diagnosis,
set `SSTERM_USE_RUST_PTY=0`; Windows remains on its established ConPTY
implementation for now.

```sh
cargo test --manifest-path native/pty_core/Cargo.toml
```
