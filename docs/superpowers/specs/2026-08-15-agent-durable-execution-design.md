# Agent durable execution and budget governance design

## Goal

Upgrade the Agent from a foreground, in-memory command loop to a bounded,
recoverable, resource-aware execution system without weakening existing command
isolation, approval gates, or provider compatibility.

## Decisions

This design is intentionally incremental. Existing `BackgroundCommandExecutor`
continues to own process creation, process-tree termination, output draining,
SSH isolation, and command safety. New Agent orchestration must consume its
results rather than introduce a second shell implementation.

1. Every agent turn receives an explicit execution budget: maximum loop
   iterations, shell calls, wall-clock duration, and estimated context tokens.
   Exceeding a budget stops safely with a structured transcript event; it never
   silently starts another model request.
2. Conversation state becomes a serializable, versioned record. It persists
   completed messages and safe terminal states only. API keys, raw environment
   variables, pending `Completer`s, live process handles, and unredacted tool
   arguments are never persisted.
3. Cancellation is represented as a structured tool result / transcript event.
   A later user instruction therefore has context that previous work was
   interrupted rather than seeing an orphaned partial assistant reply.
4. Large command output is stored as a bounded local artifact; normal feedback
   retains a concise head/tail preview and stable artifact metadata. The model
   can inspect a bounded range through a read-only tool instead of rerunning a
   costly command. Artifacts expire with their owning session.
5. Context governance is layered: exact provider usage when available; a
   conservative estimate otherwise; per-tool-result budgets before history
   summary; one reactive compaction retry for a context-length failure; then a
   clear user-visible failure. `hardLimitTokens` is a real preflight guard.

## Architecture

### Durable Agent session

`AgentSessionStore` owns atomic JSON snapshots per tab/session under the app
data directory. The record contains schema version, session ID, safe message
transcript, compacted summary, event sequence, and budget ledger. Writes are
debounced and atomic (temporary sibling followed by rename). Corrupt or
unknown-version state is quarantined and surfaced as a fresh session notice;
it is never deserialized into executable state.

The Flutter overlay treats restored state as an idle transcript. It does not
resume a model stream or shell process after app restart. A pending approval is
restored as expired/rejected, requiring the model to propose a fresh command.

### Budget and loop control

`AgentExecutionBudget` is a pure-Dart state machine. The loop consumes a unit
before each model request and command, checks deadline before waiting, and
returns an explicit terminal reason. The default budget remains deliberately
conservative and configurable only through internal constants in this release,
so old persisted configuration remains compatible.

`AgentUsageLedger` records estimated input/output usage plus provider-reported
usage where adapters expose it. It provides the context value used by
compaction and displays a compact per-turn resource summary.

### Output artifacts

`AgentOutputStore` writes only command output already captured by the executor.
It enforces per-artifact and per-session byte limits, uses restricted file
permissions where supported, and rejects traversal or arbitrary paths. A
reference consists of opaque ID, byte count, truncation state, and a preview.
The initial UI only exposes the reference; a later bounded read-only agent tool
may consume it. This keeps the first delivery safe across local and SSH tabs.

### Compatibility and security invariants

- Existing command confirmation and `CommandSafety` checks remain before every
  execution.
- The new state layer does not persist credentials, model secrets, raw MCP
  payloads, or full command output by default.
- Local, SSH, Windows, macOS, Linux, and Ollama paths retain existing request
  and shell adapters. New pure-Dart services have platform-agnostic tests.
- Every persisted record is size bounded, schema versioned, and fails closed.

## Delivery slices

1. **Delivered:** Introduce pure budget primitives and enforce them in the
   loop, including a structured cancellation/limit terminal event.
2. **Delivered:** add safe, atomic session serialization and restore idle
   transcripts only. Tool calls, approvals, runtime environment blocks, and
   command execution state never resume after restart.
3. **Delivered:** add bounded output artifacts and preview references, with
   opaque IDs, range-limited reads, owner-only POSIX permissions, and cleanup
   when the owning session is cleared.
4. **Partially delivered:** thread provider-reported prompt, completion, and
   reasoning usage through OpenAI-compatible, Anthropic, and Gemini adapters
   into context compaction. A durable cross-turn usage ledger, hard preflight,
   remain future work. A hard preflight stops an unsafe request after
   compaction when context remains too large; a single recovery retry runs
   only for an empty context-length failure.
5. Add UI affordances for current budget, interrupted state, persisted-session
   restore, and artifact references.

## Testing

- Unit tests cover all budget transitions, deadline handling, corrupt state,
  schema migration, atomic persistence semantics, artifact bounds, and path
  rejection.
- Widget tests verify cancel/new-message semantics, restored idle state, and
  never-restored approvals.
- Existing provider, shell, SSH, output-cap, and safety tests remain green.
- Full `flutter test` and `flutter analyze` are required before integration.
