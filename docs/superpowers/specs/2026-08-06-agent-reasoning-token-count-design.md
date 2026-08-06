# Agent Reasoning Token Count — Design

## Problem

When an agent streams reasoning, SSTerm shows the reasoning text but gives no
indication of how much reasoning has been generated. Users need a live signal
while the model is thinking and the exact provider-reported count when it is
available.

## Scope

1. Show an estimated reasoning-token count while reasoning is streaming.
2. Prefer the exact reasoning-token usage returned by the provider once it is
   available.
3. Retain the estimate as the final value when a provider does not supply an
   exact count.
4. Support the existing OpenAI-compatible, Anthropic, Gemini, and Ollama
   provider stream implementations without disrupting normal text or tool-call
   handling.

## Design

### Provider stream usage

Extend `LlmStreamEvent` with optional reasoning-token usage metadata. Each
provider parser extracts the reasoning token count from its terminal usage
payload where its streaming API provides one. The stream emits usage as a
provider-neutral diagnostics event, alongside the existing finish reason and
malformed-event count.

Missing, malformed, or unsupported usage is represented as absent metadata.
It must not fail the stream, discard text, or affect tool dispatch.

### Agent state and fallback estimate

The panel collects the optional exact reasoning-token count for each streamed
response. While no exact count is known, it estimates the count from the
accumulated reasoning text using a deterministic local approximation. The
estimate is only a UI fallback; it is never sent to providers or used for
billing.

The response message stores both the reasoning text and token-count display
state. At stream completion, an exact count replaces the estimate whenever one
was received. Otherwise the final displayed value remains explicitly marked as
an estimate.

Counts apply only to the response's reasoning channel. They exclude prompt,
final-answer, tool-call, and cached tokens.

### User interface

The expandable reasoning section displays a compact token label in its header:

- During streaming or without exact usage: `约 N tokens`.
- After exact usage arrives: `N tokens`.

The label updates with the existing throttled stream UI refresh and does not
change the collapsed/expanded behavior of the reasoning card. No label is
shown for assistant messages with no reasoning.

### Testing

Add deterministic parser tests for representative provider usage payloads and
unit/widget coverage that verifies exact counts take precedence over estimates,
while missing usage leaves the estimate visible. Include a non-ASCII reasoning
sample in the estimator test so Chinese reasoning remains usable as a fallback.

## Non-goals

- Showing prompt, answer, total, cached, or billing-cost token counts.
- Claiming estimates are billing-accurate.
- Changing provider models, thinking budgets, tool calling, or stream retry
  behavior.
