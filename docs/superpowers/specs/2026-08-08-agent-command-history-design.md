# Agent command history and unlimited loop design

## Goal

Remove the artificial maximum iteration stop from the agent loop and persist every completed Agent1 or Agent2 command execution locally with complete output.

## Decision

Use one append-only JSON Lines file in the application data directory:

`agent-command-history.jsonl`

Each line is one self-contained JSON object. Appending is serialized in-process so concurrent Agent1/Agent2 results cannot interleave their bytes. A crash can at worst lose the active line, while previous command records remain readable.

## Record shape

Each completed command record includes:

- `timestamp`: UTC ISO-8601 timestamp.
- `agentId`: `agent1` or `agent2`.
- `target`: local or SSH.
- `cwd`: the command's execution cwd.
- `command`: exact submitted command.
- `exitCode`: integer or null.
- `truncated`: command-result truncation flag.
- `output`: complete output returned by the execution path.
- `cancelled`: true when the host cancelled the command.

Only Agent-issued executions through `onExecuteAsync` are recorded. Manual terminal input is excluded.

## Loop behavior

Remove the `_maxLoopIterations` cap. The loop still stops for cancellation, tool/permission rejection, explicit completion, executor absence, and stream/model failures. This change does not create detached jobs.

## Reliability and privacy

The log contains complete outputs and may therefore contain secrets emitted by commands. It remains local in the application-data directory and is not uploaded. A log-write failure is caught and reported to diagnostic output only; it must never prevent a command result from reaching the agent loop.

## Validation

- Unit-test serialized JSONL append and complete-output preservation.
- Unit-test a write failure does not throw to the command caller.
- Regression-test that the loop source no longer applies a maximum-iteration stop.
- Run targeted tests, `flutter analyze`, and the complete test suite.

