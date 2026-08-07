# Agent Out-of-Terminal Execution Design

## Goal

Make the agent execute shell commands through a stable, independent,
out-of-terminal channel by default, matching the intended IDE-plugin
interaction model. The visible terminal remains a separate, user-owned
interactive session that the agent can operate only through explicit tools.

This replaces the current default path, where the agent submits commands into
the active terminal and depends on OSC 133 or a terminal-buffer sentinel to
detect completion. “Background” in this document means that execution is
separate from the visible terminal; the default `bash` call still waits for
completion and returns a result. A detached long-running task facility is a
separate future capability, not part of this change.

## Scope

- Local terminal tabs: run default agent commands in a separate non-PTY shell
  process.
- SSH terminal tabs: run default agent commands through a separate SSH exec
  channel on the existing SSH connection.
- Add explicit terminal-interaction tools for input, observation, and (when a
  completion result is required) terminal-bound command execution.
- Keep the existing dangerous-command confirmation policy, output redaction,
  cancellation, and tool-call/result cards applicable to every execution mode.

Out of scope:

- Trying to mirror arbitrary interactive shell state, aliases, functions,
  tmux sessions, REPL state, or environment mutations into the background
  executor.
- Reproducing Claude CLI's shell snapshot, persistent task-output storage, or
  CLI-specific background-task features. Those are separate product concerns
  and are not needed for the IDE-style default execution model.
- Changing ordinary user-entered terminal input or terminal rendering.

## Execution Contexts

Each terminal tab owns two explicitly separate contexts:

1. **Interactive terminal context**: the existing PTY or SSH shell displayed
   to the user. Its state belongs to the user.
2. **Agent background context**: a private execution context used by the
   default `bash` tool. It owns an agent working directory and never writes to
   the visible terminal.

The contexts do not automatically synchronise. In particular, a `cd` typed
into the visible terminal does not change the agent working directory, and a
background `cd` does not navigate the visible terminal.

This deliberate isolation prevents user activity, full-screen applications,
split-pane routing, OSC integration availability, and terminal-buffer parsing
from affecting normal agent command execution.

## Tool Contract

### `bash` — default background execution

`bash` keeps its familiar name but is redefined as a non-interactive,
background command runner.

Inputs:

- `command` (required): one shell command or script.
- Optional future controls may include timeout and working-directory override;
  the first implementation uses the tab's agent working directory.

Results include distinct `stdout`, `stderr`, `exitCode`, `timedOut`,
`truncated`, and effective `cwd` fields. The formatter may combine those for
providers that only accept text tool results, but structured fields remain
available internally.

For local tabs, execution uses a non-PTY child process launched through the
tab's selected shell. For SSH tabs, execution uses a new SSH exec channel,
not the interactive shell channel. The remote invocation starts by changing to
the agent cwd with shell-safe quoting, then runs the requested command.

The local runner must not use a bare `sh -c` regardless of the tab's selected
shell. It uses the selected shell executable with explicit non-interactive
arguments and an immutable baseline environment captured from SSTerm when the
tab's agent context is created. The baseline may include per-shell variables
already calculated by SSTerm, but it does not load, snapshot, or attempt to
mirror the live terminal's aliases, functions, `source` effects, or later
environment mutations.

### `terminal_input` — intentional terminal typing

Inputs:

- `text` (required): bytes/text to send to the active visible terminal.
- `submit` (default `false`): when true, append exactly one platform-correct
  Enter (`CR`) after the text.

This tool neither waits for completion nor claims an exit status. It is for
real interactive state: prompts, REPLs, tmux, foreground programs, or an
explicit user request to operate the terminal.

### `terminal_observe` — terminal output observation

Reads an ANSI-stripped transcript of bytes received from the terminal transport,
or output accumulated since an explicit observation cursor. It returns bounded
text plus a cursor suitable for the next incremental observation. It must
disclose when the result was truncated or the cursor has expired.

This requires a bounded, per-pane transcript ring owned by `OutputPipe` (or a
small adjacent service), populated before terminal rendering. Reading only the
xterm screen buffer is not sufficient: full-screen applications, cursor
rewrites, scrollback trimming, and ANSI control sequences make it unsuitable
as a reliable incremental-output source. A separately available `snapshot`
mode may return the rendered screen when that is explicitly what the agent
needs.

Observation does not infer whether an interactive command has completed.

### `terminal_execute` — terminal-bound capture

This tool intentionally uses the current terminal execution path and waits
for a result. It is the explicit escape hatch for commands that must use the
interactive shell's current state and can be delimited safely.

It retains the current OSC 133 primary capture, sentinel fallback, alternate
screen protection, split-pane targeting, timeout, cancellation, and recovery
behaviour. It is no longer the implementation behind default `bash`.

## Working Directory Semantics

The agent background context stores one cwd per tab.

- New local tabs initialise it from the shell process's starting directory.
- New SSH tabs initialise it from the remote login directory once available.
- A successful background command whose shell execution changes directory must
  update the stored cwd for subsequent background commands. The implementation
  should use a private, random-token completion envelope containing both exit
  status and final `pwd`, rather than parsing ordinary output. For local
  execution this metadata should travel on a private temporary file or pipe;
  for SSH execution it must use the remote command's stderr stream and be
  stripped before returning stderr to the model. It must never rely on a
  marker scanned from terminal rendering.
- Failed commands leave the stored cwd unchanged unless the final envelope
  proves a completed directory change; the initial implementation will keep
  the prior cwd on any nonzero exit to make the rule simple and predictable.
- The UI should surface the background cwd in agent context/status so users
  can understand where default commands run.

## Lifecycle and Safety

- Background command cancellation terminates only its own local process group
  or SSH exec channel. It never sends Ctrl-C to the visible terminal. The
  local target first requests graceful termination, then force-kills the whole
  child process group after a short grace period so grandchildren do not leak.
  The SSH target first sends `SIGTERM` through `SSHSession.kill`, waits briefly
  for the channel to close, then closes that exec session; it must not close
  the shared `SSHClient` transport.
- Closing a tab cancels and disposes any background work for that tab.
- At most one background command runs per tab at a time in the initial
  implementation. This preserves sequential agent semantics and makes cwd
  transitions deterministic.
- Existing command-safety checks run before invoking either `bash` or
  `terminal_execute`; `terminal_input` receives its own conservative review
  path when `submit` is true, because it can execute a command.
- The existing approval policy remains the authority for dangerous operations.
- `terminal_input` uses the same command review when `submit` is true. With
  `submit` false it is an intentional keystroke tool (for example, responding
  to a prompt), so its text is treated as sensitive tool input and redacted in
  cards/logs instead of being parsed as a shell command.
- Output limits are enforced independently for stdout and stderr. Results
  report truncation rather than silently dropping data. The executor continues
  draining both streams after the inline limits are reached, and applies an
  absolute byte watchdog that terminates a runaway task before it can exhaust
  memory or disk.

## Architecture

Introduce a transport-independent `BackgroundCommandExecutor` with a target
interface that supplies cwd, execution, cancellation, and disposal behaviour.

- `LocalBackgroundCommandTarget` starts the selected shell without a PTY,
  captures stdout/stderr separately, uses the tab's immutable baseline
  environment, and terminates the process group on timeout/cancellation.
- `SshBackgroundCommandTarget` opens an SSH exec channel, collects its stdout,
  stderr, and exit status, and closes that channel on timeout/cancellation.
- A `BackgroundCommandContext` is stored on `_Tab` and owns the per-tab cwd
  plus serialization of executions.
- A `TerminalTranscriptBuffer` is stored per terminal pane. It owns monotonic
  observation cursors, bounded decoded output, and snapshot retrieval; it is
  independent of OSC 133 command capture.
- The existing `TerminalCommandExecutor` remains focused solely on
  `terminal_execute`.
- The agent tool registry exposes `bash`, `terminal_input`, `terminal_observe`,
  and `terminal_execute`, while provider adapters use the existing canonical
  tool-call bridge.

## Error Handling

- A missing active terminal/tab yields a typed `notSupported` result.
- Failure to start a local child process or SSH exec channel returns a clear
  tool error without falling back to terminal injection.
- Timeout and cancellation have distinct result states.
- A disconnected SSH session fails the background tool clearly; reconnecting
  creates/refreshes the target before later commands can run.
- Terminal tools reject alternate-screen capture for `terminal_execute` but
  still allow `terminal_input` and `terminal_observe`, because the latter are
  explicitly interactive operations.

## Verification

- Unit tests for local command stdout/stderr/exit status, timeout,
  cancellation, process-tree cleanup, truncation, quoting, startup-environment
  snapshotting, and cwd persistence.
- Unit tests for SSH target command construction, cwd envelope parsing,
  cancellation, disconnect errors, and independent stdout/stderr collection.
- Registry and provider-contract tests covering all new tool schemas.
- Widget/loop tests proving `bash` uses the background executor and does not
  lock or write to the terminal; `terminal_execute` retains current capture
  behaviour; and `terminal_input`/`terminal_observe` are explicit calls.
- Regression tests for existing OSC 133/sentinel execution paths.
