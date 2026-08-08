# Agent2 Background Execution Design

## Goal

Add Agent2 as a temporary, fully independent agent panel for validating a
more reliable command-execution model. Agent1 remains unchanged and continues
to inject commands into the visible terminal with OSC 133/sentinel capture.

Agent2 runs normal shell commands outside the visible terminal. After real
world validation, its execution model and tests can replace Agent1; Agent1 and
its terminal-injection implementation can then be removed.

## Separation

Agent1 and Agent2 are separate panels per terminal tab. They do not share:

- conversation history or in-flight agent loop;
- command queue, cancellation generation, cwd, or pending permissions;
- tool-call/result cards or execution state.

They may share existing immutable app configuration, provider configuration,
and the tab's file-system adapter. They must never automatically run the same
command in both engines: duplicating a command can duplicate writes or other
side effects.

## Agent2 Scope

Agent2 supports only these command targets in the first release:

| Tab target | Execution |
| --- | --- |
| macOS/Linux bash or zsh | non-PTY child process |
| SSH tab with a live client | independent SSH exec session |

Windows PowerShell, cmd.exe, Git Bash, WSL, and all terminal interaction are
out of scope for Agent2 v1. Agent2 clearly reports the target as unsupported;
it never silently routes a command through Agent1 or the visible terminal.

Agent2 exposes the existing agent capabilities (questions, enabled file tools,
web search, skills, MCP) under its own conversation. Its `bash` tool is the
only changed execution capability.

## Background `bash` Contract

`bash` waits for a bounded completed result; it is not a detached background
job feature.

Inputs:

- `command` (required)

Results contain stdout, stderr, exit code, timeout/cancellation state,
truncation state, and effective Agent2 cwd. Provider adapters may render the
same information into textual tool feedback when native structured fields are
unavailable.

The agent loop retains the existing safety and confirmation policy. A failed
or unsupported Agent2 command becomes a normal structured result; it is never
re-run by Agent1 without a new, explicit user action.

## Command Context

Each Agent2 panel owns an `Agent2CommandContext` with one cwd and one
serialized active command.

- It starts from the tab's initial local directory or remote login directory.
- Agent2 displays both its own cwd and the visible terminal cwd whenever they
  differ.
- Agent2 does not automatically adopt a later terminal `cd`.
- A future explicit “adopt terminal directory” action may update Agent2 cwd;
  it is not part of v1.
- A successful command updates cwd only if a private completion envelope
  verifies its final `pwd`; a nonzero command leaves cwd unchanged.

## Execution and Cleanup

`BackgroundCommandExecutor` owns a `CommandHandle` for every running command:
request id, streams, timeout, cancellation token, completion future, and
idempotent cleanup.

- Local execution reads stdout and stderr concurrently, waits for both stream
  completion and process exit, and caps retained output while continuing to
  drain streams.
- SSH execution starts a session with `SSHClient.execute` without a PTY,
  listens to both streams before awaiting completion, and does not close the
  shared SSH client.
- Cancellation, timeout, Agent2 panel disposal, and tab disposal all converge
  through the same cleanup path.
- v1 terminates the direct child/session and reports that child processes may
  survive. Process-group containment on POSIX and Job Object containment on
  Windows are required before Agent2 becomes the replacement for Agent1, but
  are not a reason to block macOS/Linux/SSH validation.

## UI

Each terminal tab offers separately toggled Agent and Agent2 panels. Agent2 is
visibly labelled “Experimental background execution” and shows its target
capability plus cwd. Agent1's UI and behavior do not change.

The panels may both be open, but Agent2 v1 has no terminal-control tools, so
it cannot type into or lock the visible terminal. This preserves complete
execution isolation during testing.

## Validation and Promotion

Tests cover local POSIX and SSH stdout/stderr capture, exit code, timeout,
cancellation, output cap, cwd handling, unsupported-target responses, and
Agent1/Agent2 conversation isolation.

Agent2 replaces Agent1 only after manual validation confirms that long
commands do not pollute the visible terminal; command completion is derived
from process/session lifecycle rather than terminal markers; and cancellation,
nonzero exits, and SSH execution return correct structured results.
