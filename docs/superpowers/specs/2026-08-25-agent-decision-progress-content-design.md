# Decision progress should accompany, not replace, chat content

## Goal

For an adaptive-decision run, keep the decision card as compact operational
telemetry while showing useful, user-readable progress in the transcript.
The card must never be the only visible evidence that the model is working.

## Transcript model

The existing decision card remains immediately after the user message. It
shows the current stage, elapsed time, request count, token totals and a
cancel control.

Each completed internal stage adds a normal assistant transcript message:

1. Planning: a concise summary of the candidate approach, or a clear note
   that planning was unavailable.
2. Review: the selected recommendation and its rationale.
3. Execution: the existing streamed assistant reply continues to render in
   its regular assistant message without being replaced by the card.
4. Verification: the existing final status remains reflected by both the
   decision card and final assistant reply.

Internal prompts, raw JSON, and hidden chain-of-thought are never exposed.
Only the structured plan fields already returned by the deliberation module
are formatted into short user-facing summaries.

## State and failure handling

The decision card continues to show live request state and usage. A missing
usage payload is labelled as unavailable only after the corresponding request
finishes; while a request is active it is simply pending.

If planning or review fails, add a concise transcript notice and proceed with
the existing standard-execution fallback. This makes the fallback visible
instead of leaving a card that appears to be silently waiting.

## Tests

Add behavioral/source coverage proving that a deep decision run creates
normal assistant transcript entries for planning and recommendation, while the
streamed execution reply remains a separate regular assistant message.
Regression coverage must also retain the operational card controls and token
aggregation behavior.
