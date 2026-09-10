use std::time::Instant;

use ssterm_terminal_core::TerminalCore;

fn measure(label: &str, input: &[u8], scrollback_rows: usize, chunk_size: usize) {
    let mut terminal = TerminalCore::with_scrollback(160, 48, scrollback_rows);
    for run in 1..=2 {
        let started = Instant::now();
        for chunk in input.chunks(chunk_size) {
            terminal.feed(chunk);
        }
        let elapsed = started.elapsed();
        let mib_per_second = input.len() as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64();
        println!(
            "{label} scrollback={scrollback_rows} chunk={chunk_size} run={run}: {:.2} MiB/s ({} bytes in {:.3}s)",
            mib_per_second,
            input.len(),
            elapsed.as_secs_f64()
        );
    }
}

fn main() {
    // A representative stream: colored build/log output plus cursor controls.
    // This is intentionally deterministic so developers can compare runs.
    let line = b"\x1b[1;38;5;39mbuild\x1b[0m package=ssterm status=ok elapsed=12ms\r\n";
    let mut input = Vec::with_capacity(16 * 1024 * 1024);
    while input.len() < 16 * 1024 * 1024 {
        input.extend_from_slice(line);
    }

    let mut seq = Vec::with_capacity(17 * 1024 * 1024);
    for value in 1..=2_000_000 {
        seq.extend_from_slice(value.to_string().as_bytes());
        seq.extend_from_slice(b"\r\n");
    }

    measure("build-log", &input, 10_000, 4096);
    measure("seq", &seq, 10_000, 4096);
    measure("seq", &seq, 10_000, 1024 * 1024);
    measure("seq", &seq, 0, 4096);
}
