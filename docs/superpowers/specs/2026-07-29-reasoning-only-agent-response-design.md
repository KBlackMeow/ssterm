# Reasoning-only Agent Response — Design

## Problem

An OpenAI-compatible streaming response can contain `reasoning_content` but no
final `content` or parsed tool call. SSTerm currently renders the reasoning,
logs `warn empty_reply`, and ends the agent loop as though it were successful.
The user receives neither an answer nor an actionable error.

The problem became more likely after native tool calling was enabled for all
non-Ollama providers. The current evidence cannot distinguish a provider/model
that ended after reasoning from an unsupported tool-stream response because the
SSE parser silently discards every parsing error and does not report the stream
finish reason.

## Scope

1. Preserve diagnostics for OpenAI-compatible SSE stream completion and
   malformed events without exposing response content or secrets.
2. Correctly assemble streamed OpenAI tool calls whose later argument chunks
   contain an `index` but omit the initial `id` and function `name`.
3. Treat a reasoning-only response with no text and no valid tool call as an
   explicit, user-visible agent error. Do not execute a command or silently
   retry the original request.
4. Cover parser and terminal-state behavior with deterministic tests.

## Design

### Provider stream outcome

Introduce a provider-neutral stream diagnostic event or result metadata that
records only event category, parse failure count, and completion reason. The
panel must retain the existing visible reasoning but receive enough metadata to
differentiate a clean reasoning-only completion from an unreadable response.

For OpenAI-compatible streams, retain an `index -> id` mapping. The first
delta normally supplies an id; later deltas refer only to the index. Append
every function-arguments fragment to the buffer associated with that stable id,
then emit a tool call only after the stream ends and JSON arguments validate.

Do not use `catch (_) {}`. A malformed individual data event may be skipped so
one bad SSE record cannot corrupt a live turn, but it must increment a counter
and emit a redacted diagnostic through the existing agent logging path.

### Agent-loop terminal state

After collection, a response is valid when it contains displayable final text,
a valid tool call, or a recognized completion/ask marker. A response that has
reasoning but none of those is invalid. Replace its empty assistant placeholder
with a clear error card explaining that the selected provider returned thought
without an answer or usable tool call. Include the completion reason when the
provider supplied one, otherwise state that it was unavailable.

No automatic retry is included. Retrying the same request after a successful
but incomplete provider completion can duplicate writes or command proposals.
The user can resend after correcting provider/model configuration.

### Tests

Add deterministic tests using a local HTTP SSE fixture for:

- reasoning plus final text;
- reasoning plus a fragmented native tool call, where later chunks omit id;
- reasoning-only completion resulting in a surfaced error;
- malformed SSE JSON being reported rather than silently indistinguishable
  from an empty normal response.

## Non-goals

- Changing OSC133, MCP connection handling, or command safety policy.
- Retrying model requests automatically.
- Capturing or logging raw model reasoning, response text, API keys, or tool
  arguments beyond existing redacted metrics.
