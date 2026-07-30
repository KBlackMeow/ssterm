# Reasoning-only Agent Response Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface and diagnose provider responses that contain reasoning but no final answer or usable tool call, while correctly preserving fragmented native tool calls.

**Architecture:** Extend the streaming result with minimal completion diagnostics, make the OpenAI-compatible SSE assembler index-aware, then make the agent loop reject a reasoning-only terminal response instead of silently ending. Tests exercise the public streaming seam through local SSE fixtures and the loop-state decision through a small pure helper.

**Tech Stack:** Dart, Flutter, `dart:io` HTTP/SSE, package:test.

## Global Constraints

- Do not log raw model text, reasoning, tool arguments, API keys, or terminal output.
- Preserve the existing assistant reasoning display.
- Do not automatically retry a completed reasoning-only response.
- Preserve the user's uncommitted native-tool-calling work; stage only files intentionally changed for this fix.

---

### Task 1: Make OpenAI-compatible SSE outcomes observable and tool chunks stable

**Files:**

- Modify: `lib/services/llm_service.dart`
- Modify: `lib/services/llm_service_providers.dart`
- Test: `test/services/llm_service_test.dart`

**Interfaces:**

- Produces an internal stream-result metadata value containing `finishReason`, `malformedEventCount`, and emitted text/tool-call counts.
- Consumes OpenAI SSE `choices[0].delta.tool_calls[*].index`, optional `id`, function `name`, and function `arguments` fragments.

- [ ] **Step 1: Write failing parser tests**

  Add local SSE fixture tests that assert a tool call beginning with
  `{index: 0, id: 'call_1', function: {name: 'ask_user_question', arguments: '{'}}`
  and continuing with `{index: 0, function: {arguments: '\"question\":\"Which?\"}'}}`
  becomes one valid `AgentToolCall`. Add a malformed `data:` JSON record and
  assert the metadata count is one while later valid text still arrives.

- [ ] **Step 2: Run the focused tests and verify RED**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: new fragmented-tool and malformed-event assertions fail because
  there is no index-to-id association or diagnostic metadata.

- [ ] **Step 3: Implement the minimal SSE assembler and diagnostics**

  Keep `Map<int, String> toolIdByIndex`; set it when a chunk includes both
  fields and reuse it when later chunks include only `index`. Maintain a
  per-tool argument buffer keyed by stable id. Read `finish_reason` from each
  choice when supplied. Replace the blanket parse catch with a narrow handler
  that increments malformed-event count and logs only event type/count.

- [ ] **Step 4: Run the focused tests and verify GREEN**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: PASS.

### Task 2: Make reasoning-only replies a visible failed terminal state

**Files:**

- Modify: `lib/widgets/ai_assistant_panel_tooling.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Test: `test/services/llm_service_test.dart` or a new pure-Dart test for the extracted response classifier.

**Interfaces:**

- Consumes stream text, reasoning-present boolean, valid tool calls, completion markers, and stream diagnostics.
- Produces a terminal classification: valid reply or descriptive incomplete-response error.

- [ ] **Step 1: Write the failing classification test**

  Extract a small pure helper if needed and test that `{text: '', hasReasoning:
  true, toolCalls: const [], finishReason: 'stop'}` returns an incomplete
  response error; test that text or one valid tool call remains valid.

- [ ] **Step 2: Run the focused tests and verify RED**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: the reasoning-only case fails because the current loop reports
  only a warning and treats it as ordinary no-command completion.

- [ ] **Step 3: Implement the minimal state transition**

  Return reasoning presence and diagnostics from `_streamAiResponse`. Before
  adding an empty assistant response to conversation history, detect the
  reasoning-only invalid state, replace the placeholder with an error message,
  log reason/count metrics, and stop the loop. Do not add the empty assistant
  turn to history and do not retry.

- [ ] **Step 4: Run the focused tests and verify GREEN**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: PASS.

### Task 3: Verify the integrated fix

**Files:**

- Modify: files from Tasks 1–2 only.

- [ ] **Step 1: Format changed Dart files**

  Run: `dart format lib/services/llm_service.dart lib/services/llm_service_providers.dart lib/widgets/ai_assistant_panel_tooling.dart lib/widgets/ai_assistant_panel_loop.dart test/services/llm_service_test.dart`

- [ ] **Step 2: Run static analysis**

  Run: `flutter analyze`

  Expected: no new diagnostics.

- [ ] **Step 3: Run the complete test suite**

  Run: `flutter test`

  Expected: PASS.

- [ ] **Step 4: Inspect scope**

  Run: `git diff --check && git diff --stat`

  Expected: no whitespace errors and only the intended provider/agent/test/docs files changed.
