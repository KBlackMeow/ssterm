# Native Tool-call Card — Design

## Problem

Native provider responses carry function calls in structured response fields,
not assistant text. SSTerm currently executes those calls and renders MCP
results or shell confirmation cards, but does not show what the model asked to
call. A response containing several calls therefore appears as blank assistant
content followed only by results.

## Scope

1. Show every native tool call in the chat transcript before execution.
2. Keep a compact summary for multiple calls and let the user expand details.
3. Display the tool name, call id, and JSON arguments in a selectable,
   monospace view.
4. Redact values for argument keys containing `token`, `password`, `secret`,
   `api_key`, or `authorization`, case-insensitively.
5. Limit a displayed argument value to 2,000 characters, with an explicit
   truncation suffix. The execution payload and provider transcript remain
   unchanged.

## Design

Add a private `_ToolCallData` payload to `_ChatMessage`, plus a
`_ChatMessage.toolCalls` factory. It owns an immutable list of normalized
`ToolCall` values from the active response. The agent loop appends this chat
message after the model reply is received and before dispatching MCP, shell, or
host-managed tools.

Add `_ToolCallCard` in `ai_assistant_panel_content.dart`. Its collapsed header
states either `Calling <tool name>` or `Calling N tools`; expanding it renders
one row per call. A row has a readable title, a short call id, and formatted
arguments. Shell calls show their `command` argument under the same redaction
and truncation policy. The card is informational only; it has no action button
and does not alter confirmation or execution behavior.

Place formatting and redaction in a small pure-Dart helper near the message
models, so it can be tested without widget rendering. It recursively processes
JSON maps and lists, redacts sensitive map values, then pretty-prints the
sanitized structure.

## Tests

- A native tool-call model payload creates one chat-card payload containing all
  calls in original order.
- Sensitive fields are replaced with `[redacted]`, including nested fields.
- Long argument values receive the truncation suffix.
- Multiple calls produce the plural card summary; a single call produces the
  singular summary.

## Non-goals

- Changing tool execution order, confirmation policy, MCP results, or provider
  request formats.
- Showing raw credentials, raw provider reasoning, or unbounded binary data.
