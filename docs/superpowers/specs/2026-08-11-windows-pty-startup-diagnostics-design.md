# Windows PTY Startup Diagnostics Design

## Goal

When a local PowerShell PTY fails to start, show enough Windows-native detail
in the affected SSTerm terminal to diagnose intermittent failures without an
external debugger.

## Design

The Windows PTY native layer records the exact failing stage together with the
relevant Win32 or HRESULT code and its `FormatMessageW` system description.
The error is returned as owned data from the background isolate instead of
being read later through isolate-local FFI state.

The Dart launch boundary adds safe context: executable path, working directory,
argument count, and argument lengths. It never includes complete arguments,
encoded PowerShell scripts, or environment values. The existing local-terminal
failure handler displays the resulting `PtyStartException`; successful startup
remains silent.

## Testing

Unit tests cover formatting and redaction of startup context. Source-level
tests lock down Windows native stage/code/system-message diagnostics and owned
error transfer across the isolate boundary. Existing Flutter tests and static
analysis guard surrounding behavior.
