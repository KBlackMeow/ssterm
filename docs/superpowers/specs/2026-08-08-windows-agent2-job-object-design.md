# Windows Agent2 background execution and Job Object design

## Goal

Enable Agent2 local background execution on Windows without using the visible terminal, and ensure cancellation/timeout terminates the complete process tree through a Windows Job Object.

## Shell routing

- PowerShell and pwsh execute through their real executable with noninteractive command arguments.
- cmd executes through `/d /s /c`.
- Git Bash executes through `-c`.
- WSL executes through `wsl.exe -- <distribution arguments> sh -lc` using its Linux cwd representation only when it is available.
- Unsupported/misconfigured shells return an explicit result and never fall back to terminal injection.

## Lifecycle

A native Windows helper creates a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, assigns the started process to it, and exposes close/terminate through Dart FFI. Cancellation and timeout terminate the Job Object, including descendants. Normal completion closes the Job Object after stdout/stderr drains.

## Boundaries

This phase changes Windows only. POSIX process-group cleanup remains a separate next phase. Full output history continues through the existing host wrapper.

## Validation

- Unit-test Windows shell command construction.
- Add Windows integration tests for direct completion and a parent/child cancellation case.
- Verify terminal PTY remains usable after Agent2 cancellation.

