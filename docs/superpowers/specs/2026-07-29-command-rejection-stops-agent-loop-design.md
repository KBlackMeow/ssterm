# Command rejection stops the agent loop

## Goal

When a user rejects a proposed shell command in the AI assistant, the current
agent task ends immediately. The assistant must not make another LLM request
as a consequence of that rejection.

## Behaviour

- The rejected command is never sent to the shell.
- Its proposal card remains visibly rejected in the chat transcript.
- No remaining command from the same LLM response runs.
- The loop does not append rejection feedback to model history and does not
  start another LLM iteration.
- Existing cancellation and stale-generation behaviour remains unchanged.

## Design

`_runAgentLoop` already executes shell tool calls in order. In the `!approved`
branch, after preserving the existing rejection diagnostic logging and UI
state, exit the loop directly. This prevents the normal feedback aggregation
path from creating a next-turn user message and requesting the model again.

No new state or exception type is needed: rejection is a terminal condition of
the current loop, analogous to the existing task-complete and no-executor
termini.

## Testing

Add a widget-level regression test with a response that proposes a command,
reject it, and assert the configured LLM callback is called only once. The test
also verifies that the rejected command is not executed.
