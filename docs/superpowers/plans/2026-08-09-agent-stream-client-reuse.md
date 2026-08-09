# Agent Stream Client Reuse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse one `HttpClient` pool across all model iterations in a single Agent task, rebuild it on zero-content transient failures, and always close it when the task ends.

**Architecture:** Introduce a small injectable session object that owns the current `HttpClient`, then pass that session through the Agent loop instead of creating a client per request. Retry policy remains in the panel tooling layer, but resets the session before retry and uses deterministic exponential delays.

**Tech Stack:** Dart 3.11, Flutter, `dart:io` `HttpClient`, `flutter_test`. No new dependencies.

## Global Constraints

- One client session per Agent task/generation; no global cross-task pool.
- Close on success, failure, cancellation, and stale generation.
- Retry only before any text, reasoning, or tool call arrives.
- At most three attempts with 500 ms then 1500 ms delays.
- Reset the client before every retry so DNS and TLS are re-established.
- Never log API keys, headers, messages, commands, or output.
- Do not change command feedback or risk classification.

---

### Task 1: Stream client session lifecycle

**Files:**
- Create: `lib/services/agent_stream_client_session.dart`
- Create: `test/services/agent_stream_client_session_test.dart`

**Interfaces:**
- Produces: `AgentStreamClientSession({HttpClient Function()? clientFactory, void Function(HttpClient, {required bool force})? clientCloser})`
- Produces: `HttpClient get client`
- Produces: `void reset()`
- Produces: `void close({bool force = false})`

- [ ] **Step 1: Write failing lifecycle tests**

Inject real `HttpClient` instances plus a recording close callback. Assert repeated `client` reads return one instance, `reset` closes it forcefully and creates a new instance on next read, normal `close` is idempotent, forced close forwards `force: true`, and accessing `client` after final close throws `StateError`.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/agent_stream_client_session_test.dart`

Expected: FAIL because the session file and type do not exist.

- [ ] **Step 3: Implement the minimal session**

Implement explicit `_client`, `_closed`, and injected factory state. `reset()` closes only the current client and keeps the session reusable; `close()` marks it terminal before closing the current client. Both operations are idempotent.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/services/agent_stream_client_session_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/agent_stream_client_session.dart test/services/agent_stream_client_session_test.dart
git commit -m "feat: add agent stream client session"
```

### Task 2: Reuse the session across Agent iterations

**Files:**
- Modify: `lib/services/llm_service.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart`
- Modify: `test/services/llm_service_test.dart`
- Modify: `test/widgets/agent_panel_layout_invariants_test.dart`

**Interfaces:**
- Consumes: `AgentStreamClientSession` from Task 1.
- Produces: `LlmService.chatStream({required AgentConfig config, required List<AgentConversationItem> messages, required HttpClient client, required void Function() cancel})` or an equivalent request API that does not own the task-level client.

- [ ] **Step 1: Write failing integration invariants**

Assert the Agent response entry creates one session outside the loop, `_streamAiResponse` receives that session, `LlmService.chatStream` uses `session.client`, retry invokes `session.reset()`, and the outer task closes the session in `finally`. Assert retry delays are exactly 500 and 1500 milliseconds and `nativeToolCalls.isEmpty` participates in the retry predicate.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart test/services/llm_service_test.dart`

Expected: FAIL because each request still constructs its own `HttpClient` and retry ignores received tool calls.

- [ ] **Step 3: Refactor request ownership**

Import the session service into the panel library. Create one session in `_agentRespond`, pass it into `_continueAgentLoop` and `_streamAiResponse`, and close it in the outermost `finally`. Change `LlmService.chatStream` to use the supplied client and expose request cancellation without making successful iteration completion close the whole task session.

- [ ] **Step 4: Harden retries**

Set `maxAttempts = 3`. Before attempt 2 wait 500 ms; before attempt 3 wait 1500 ms. Include `nativeToolCalls.isEmpty` in `canRetry`. Before retry call `session.reset()`, then the next attempt obtains `session.client`. Add provider id and sanitized scheme/host/port to the retry log.

- [ ] **Step 5: Verify focused GREEN**

Run: `flutter test test/services/agent_stream_client_session_test.dart test/services/llm_service_test.dart test/widgets/agent_panel_layout_invariants_test.dart`

Expected: PASS.

- [ ] **Step 6: Run full verification**

Run: `dart format lib/services/agent_stream_client_session.dart lib/services/llm_service.dart lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_tooling.dart test/services/agent_stream_client_session_test.dart test/services/llm_service_test.dart test/widgets/agent_panel_layout_invariants_test.dart && flutter test && flutter analyze lib test && git diff --check`

Expected: all tests pass; analysis introduces no new errors or warnings beyond the repository baseline; no whitespace errors.

- [ ] **Step 7: Commit**

```bash
git add lib/services/llm_service.dart lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_tooling.dart test/services/llm_service_test.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "fix: reuse agent streaming connections"
```
