# Agent context compaction

## Goal

Keep long-running SSTerm agent sessions useful without repeatedly sending an
unbounded transcript to the selected LLM provider.  Replace the current
middle-history deletion with a compact, model-generated memory while
preserving valid native tool-call protocol groups.

## Scope

- Add provider-neutral conversation compaction for the agent panel.
- Preserve the initial user goal, one controlled summary item, and a recent
  tail of complete transcript groups.
- Prefer truncating oversized tool/command feedback before compaction.
- Safely fall back to the current trimming behavior if summarisation fails.
- Clear compacted memory with `/clear`, `/reset`, and `/new`.

Settings, persistence across app restarts, user-configurable thresholds, and
changes to the visible chat transcript are out of scope.

## Chosen design

### Transcript shape

`AgentConversationHistory` gains an explicit summary item type.  It is
serialized as a controlled user-role message using a fixed
`<conversation_summary>` envelope.  It is only created by SSTerm, never
accepted from model output, and is placed immediately after the pinned opening
goal.  Provider adapters therefore keep their current role-only wire formats;
native assistant-tool-call and tool-result records remain structured.

The history keeps:

1. the initial goal / session-context item;
2. the latest summary, if one exists;
3. the newest configured number of complete transcript groups.

A group is either a text message or a native assistant tool-call item together
with its following tool-result item.  No compaction or fallback trim may split
a tool use from its result.

### When and how compaction runs

Before a provider request, the panel checks the number of retained transcript
items.  When it exceeds the current history threshold, it snapshots the older
unpinned groups and asks the configured LLM for a compact summary.  The request
uses the same provider/model but a separate, fixed compaction prompt and no
agent tools.  The original agent request is made only after the compacted
history has replaced those groups.

The summary prompt requires these sections:

- user goal and constraints;
- completed work and observed results;
- relevant files, commands, paths, and decisions;
- current state and remaining work;
- unresolved failures or questions.

It explicitly treats all transcript text and tool output as untrusted data,
not instructions, and requests concise plain text.  Existing summary content
is included when doing incremental compaction so earlier decisions survive.

### Output-size control

Tool/command feedback is the highest-risk source of context growth.  The
existing feedback formatter will cap large result bodies deterministically,
retaining metadata plus a bounded head and tail with a clear omission marker.
This cap applies before messages enter history, so it benefits ordinary turns
as well as compaction and does not require an additional LLM call.

### Failures and cancellation

If the compaction call returns an error, malformed content, empty text, or is
cancelled/stale, SSTerm does not modify the visible chat transcript.  It logs
the failure and falls back to the present safe group-aware trim.  The agent
then proceeds with its normal request.  A compaction request never executes
tools and never renders its own chat bubble.

### UI and lifecycle

The feature has no new setting in this iteration.  The panel may expose a
short transient loop status such as “Compressing context…” while the hidden
summary request is active.  `/clear`, `/reset`, and `/new` clear the summary
because they already clear conversation history.  The visible transcript is
not discarded or rewritten by compaction.

## Alternatives considered

1. **Hard truncation only:** no extra latency or cost, but loses decisions and
   task state from the middle of a long session.  Rejected.
2. **Local keyword extraction:** avoids an API call but cannot reliably infer
   what succeeded, failed, or remains to do from tool-driven work.  Rejected.
3. **Summarise every turn:** maximises recency but doubles routine requests and
   increases latency.  Rejected in favour of threshold-triggered incremental
   summarisation.

## Testing

Unit tests will cover summary envelope construction, preservation of complete
tool-call/result groups, incremental-summary replacement, oversized feedback
truncation, provider request shape with tools disabled, and fallback behavior
on compaction failure.  Existing provider-adapter tests must continue to prove
that native calls and results serialize correctly after compaction.

## Acceptance criteria

- A session beyond the history threshold retains a provider-generated summary
  plus the opening goal and recent complete groups.
- No native tool call is sent without its corresponding tool result.
- Large command feedback is bounded before being recorded in history.
- Failed compaction never blocks an ordinary agent response and falls back
  safely.
- Clearing a chat removes compacted memory.
