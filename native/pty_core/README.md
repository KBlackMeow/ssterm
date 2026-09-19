# SSTerm PTY core

`pty_core` owns the portable native PTY session lifecycle: process creation,
reader/writer handles, resize, child exit observation, and termination. On
macOS/Linux it is implemented with `portable-pty` over Unix PTYs. On Windows it
uses a hand-rolled ConPTY session (`src/windows.rs`) that mirrors the Windows
Terminal architecture: it prefers the vendored `conpty.dll` sidecar (see
`windows/conpty/`) and otherwise falls back to the inbox kernel32
`CreatePseudoConsole`, reads through an overlapped double-buffered 128 KiB
pipe, answers the sidecar's DA1 startup query so sessions never stall waiting
for a terminal reply, and terminates the child by PID so a blocked exit
waiter can never deadlock teardown.

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
executable directly. Rust is the default on macOS, Linux, and Windows. On
Windows, `wsl.exe` and installed distribution launchers use the same Rust
reader, 64 KiB chunks, and bounded ACK window as native shells. To force the
legacy C implementation during diagnosis, set `SSTERM_USE_RUST_PTY=0`.

The Windows ConPTY transport is selected per session at load time. The
Windows build installs the redistributable `conpty.dll` and `OpenConsole.exe`
from the Microsoft.Windows.Console.ConPTY package next to the executable, so
the sidecar transport is the default; without those files the inbox kernel32
pseudoconsole is used instead. The sidecar matters for throughput: it opens
each session with a `CSI c` (DA1) query and stalls roughly three seconds
until a reply arrives, and once answered it sustains far higher flood rates
than the inbox host on the same machine — `seq 1 1000000` through `wsl.exe`
drains ~7.9 MB in ~0.5 s (~16 MB/s, small overlapped chunks) versus ~2.6-2.9 s
(~3 MB/s) over kernel32 with the inbox conhost. Windows Terminal itself
measures ~0.32 s for the same workload on the same machine with its own
bundled sidecar.

```sh
cargo test --manifest-path native/pty_core/Cargo.toml
```
