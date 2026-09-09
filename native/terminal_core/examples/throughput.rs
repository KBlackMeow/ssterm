use std::time::Instant;

use ssterm_terminal_core::TerminalCore;

fn main() {
    // A representative stream: colored build/log output plus cursor controls.
    // This is intentionally deterministic so developers can compare runs.
    let line = b"\x1b[1;38;5;39mbuild\x1b[0m package=ssterm status=ok elapsed=12ms\r\n";
    let mut input = Vec::with_capacity(16 * 1024 * 1024);
    while input.len() < 16 * 1024 * 1024 {
        input.extend_from_slice(line);
    }

    let mut terminal = TerminalCore::with_scrollback(160, 48, 10_000);
    let started = Instant::now();
    for chunk in input.chunks(4096) {
        terminal.feed(chunk);
    }
    let elapsed = started.elapsed();
    let mib_per_second = input.len() as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64();
    println!(
        "terminal_core: {:.2} MiB/s ({} bytes in {:.3}s)",
        mib_per_second,
        input.len(),
        elapsed.as_secs_f64()
    );
}
