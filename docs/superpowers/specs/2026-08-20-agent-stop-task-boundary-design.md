# Agent Stop Task Boundary

## Goal

Make Stop end the active Agent task.  The next user message starts a new
primary task: prior chat history may be used only as factual reference, and
the Agent must not autonomously resume the stopped task's plan, commands, tool
calls, or follow-up work.

## Problem

Today `_cancelAgent()` cancels the active model stream and background command,
but retains `_conversationHistory`.  The next call sends that full history to
the provider.  A model can therefore infer that the previous user goal remains
unfinished and continue it even when the newest message asks something else.

Input typed before cancellation completes can also be in
`_pendingUserInput`.  `_cancelAgent()` currently drains that FIFO queue after
teardown, which can revive a message that the user expects Stop to discard.

## Behavior

### Stop

- Cancel the active model stream and command using the existing generation
  cancellation path.
- Clear `_pendingUserInput`; Stop discards all requests that were queued for
  the cancelled task.
- Preserve the visible transcript and existing conversation history.
- Record an internal task-boundary flag.  This is transient per tab and is not
  displayed as a chat message or persisted as a new user/assistant turn.

### First message after Stop

When the next user message is sent, prepend a host-authored control block to
that user message before appending it to `AgentConversationHistory`.  The
block states that:

- the preceding task was stopped by the user and must remain stopped;
- the latest user message is the new primary task and takes precedence over
  every earlier request;
- history is reference-only: it may be quoted for facts, completed results,
  and context, but must not cause commands, tools, plans, or follow-up work
  for the stopped task to resume unless the latest message explicitly requests
  that work.

The flag clears once this boundary block has been attached, so later turns
continue normally within the new task.

## Data flow

1. User taps Stop.
2. `_cancelAgent()` increments `_generation`, cancels the stream/process,
   clears pending decisions as it does today, clears the input queue, and sets
   the pending-new-task boundary flag.
3. User sends a new prompt. `_agentRespond()` sees the flag, builds the normal
   environment/session context, and includes the boundary control block with
   the newest prompt in one user history item.
4. `LlmService.chatStream` still receives complete history, so it can answer
   questions about previously obtained facts, but the latest instruction
   explicitly defines the only task the Agent may autonomously pursue.

## Error handling and compatibility

- Stop remains safe if no model call or command is in flight.
- Repeated Stop presses keep the flag set and leave the input queue empty.
- `/clear` still clears both transcript and history; it also resets the
  boundary flag, because the next prompt is already a fresh conversation.
- Session restore continues to restore only idle history.  The boundary flag is
  transient, so a restarted app does not manufacture a cancellation event.
- No provider-specific protocol changes are needed.  The control block is
  ordinary user content and is serialized through existing OpenAI, Anthropic,
  Gemini, compatible, and Ollama paths.

## Tests

Add focused source-level/widget invariant coverage alongside the existing
Agent selection tests:

- Stop clears `_pendingUserInput` before teardown can drain it.
- Stop marks the next outgoing Agent request as a new-task boundary.
- The first prompt after Stop contains the boundary controls and the literal
  latest prompt in the same history item.
- The boundary applies once only; the following prompt does not repeat it.
- `/clear` resets the pending boundary state.

Run the focused Agent test file and the full Flutter test suite before
completion.

## Out of scope

- Clearing the visible transcript or permanently deleting historical model
  context on Stop.
- Attempting to prevent a process deliberately detached by a shell command
  (`nohup`, daemonization, etc.) from continuing outside the managed process
  tree.
- Changing the existing command-risk, approval, or file-write policies.
