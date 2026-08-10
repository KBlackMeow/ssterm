# Remove Agent1 and OSC 133

## Goal

Replace the two-agent experiment with one background-executing Agent, remove
all command injection into the visible terminal, and remove OSC 133 shell
integration from local, WSL, PowerShell, and SSH shells. Keep OSC 7 working
directory reporting.

## Scope

- Delete Agent1's overlay, lifecycle state, terminal lock, command sender,
  `TerminalCommandExecutor` integration, OSC status UI, and command-history
  identity.
- Promote Agent2 to the only Agent. Rename user-facing labels and internal
  state where practical so the product no longer exposes Agent1/Agent2.
- Run all Agent shell commands through the existing background executor for
  local and SSH tabs. Unsupported shells return explicit errors and never
  fall back to visible-terminal injection.
- Remove OSC 133 C/D emission, parsing, capture state, and tests from every
  supported shell path.
- Retain OSC 7 cwd emission and parsing for visible terminal tabs.
- Preserve unrelated terminal behavior, file tools, web search, permissions,
  command-risk classification, cancellation, and command history.

## Agent architecture

Each terminal tab owns one Agent overlay and one independent background cwd.
The overlay uses the current Agent2 execution path:

- Local tabs start a supported non-PTY background shell.
- SSH tabs execute through the existing independent SSH command channel.
- Cancellation terminates only the Agent command.
- No Agent action writes bytes to the visible terminal PTY.

The Agent is presented without an experimental badge or numeric suffix. UI
controls that paste or execute AI code through the visible terminal are
removed from the Agent surface. Ordinary user paste and keyboard input remain
unchanged.

## Configuration migration

The canonical configuration names become `agentPosition` and `agentSize`.
When loading older configuration, use the former Agent2 layout values when
present because Agent2 is the implementation being promoted. Existing Agent1
layout values are used only as a compatibility fallback when no Agent2 value
exists. Saving writes only the canonical fields.

Per-tab transient Agent2 fields become the canonical Agent fields. No Agent1
conversation is merged into the promoted Agent conversation because the two
histories were intentionally isolated and are not persisted across launches.

Command history writes `agent` as the canonical identity. Readers continue to
accept historical `agent1` and `agent2` records.

## Shell integration

### OSC 7 retained

Local bash/zsh, WSL, native PowerShell, and interactive SSH wrappers continue
to emit OSC 7 when the prompt is rendered. This keeps the visible tab's cwd in
sync for restart behavior, file operations, and display.

PowerShell retains a small prompt wrapper delivered with `-EncodedCommand`.
It chains to the user's existing prompt and emits only OSC 7. It does not
import PSReadLine, replace Enter, inspect exit status, or emit OSC 133.

### OSC 133 removed

Delete bash/zsh preexec and precmd hooks, PowerShell PSReadLine and exit-code
hooks, SSH equivalents, and WSL copies of those hooks. Remove the output-pipe
OSC 133 command-boundary capture state and the shell-integration parser when
it has no remaining consumer.

No sentinel fallback is retained for Agent execution because the promoted
Agent receives output and exit status directly from its background process or
SSH command channel.

## Failure behavior

Unsupported or disconnected background targets produce an explicit tool
result. They never send the command to the visible terminal. PowerShell PTY
startup failures remain visible in the terminal, while the PowerShell launch
command is substantially smaller after OSC 133 removal.

The native PTY error-code propagation defect discovered during diagnosis is
outside this change unless modifying the same startup boundary is required to
lock down a regression test; it should otherwise be handled separately.

## Tests

Use test-first changes at the closest stable seams:

- Assert every local, PowerShell, WSL, and SSH shell wrapper emits OSC 7 and
  contains no OSC 133 markers or PSReadLine Enter hook.
- Assert the application builds only one Agent overlay and wires it to the
  background command executor without terminal send callbacks.
- Assert legacy Agent2 layout JSON loads into canonical Agent layout and that
  saves no longer emit Agent1/Agent2 layout keys.
- Assert command history writes the canonical `agent` identity while legacy
  records remain readable.
- Remove obsolete `TerminalCommandExecutor` and OSC 133 capture tests after
  their production code is deleted.
- Run focused service/widget tests, static analysis, and the full Flutter test
  suite before completion.

## Out of scope

- Removing OSC 7 or making visible-terminal cwd tracking injection-free.
- Adding a terminal-execution fallback to the promoted Agent.
- Migrating in-memory Agent1 conversations into Agent history.
- Redesigning the command safety or file permission systems.
