# Agent Reasoning Token Count Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a live estimated token count for streamed agent reasoning, then replace it with the provider-reported exact reasoning-token count when available.

**Architecture:** Add provider-neutral optional reasoning-token usage to stream diagnostics. The assistant panel stores the exact count separately from the reasoning text and uses a deterministic local estimator until exact usage arrives. The reasoning card renders the exact count unqualified and the fallback estimate with `约`.

**Tech Stack:** Dart, Flutter, `dart:convert`, Flutter test.

## Global Constraints

- Count only the response reasoning channel; exclude prompt, final-answer, tool-call, cached, and billing-cost tokens.
- Prefer exact provider usage, and label all fallback values with `约`.
- Missing or malformed usage must not interrupt normal streamed text or tool calling.
- Preserve the existing collapsible reasoning-card behavior and stream refresh throttling.

---

### Task 1: Carry exact reasoning usage through provider streams

**Files:**

- Modify: `lib/services/llm_service.dart:26-53`
- Modify: `lib/services/llm_service_providers.dart:273-431, 439-539, 541-613, 698-763`
- Test: `test/services/llm_service_test.dart:13-84`

**Interfaces:**

- Produces `LlmStreamEvent.diagnostics({String? finishReason, required int malformedEventCount, int? reasoningTokenCount})`.
- Consumes provider terminal-usage fields that independently identify reasoning: OpenAI-compatible `usage.completion_tokens_details.reasoning_tokens` and Gemini `usageMetadata.thoughtsTokenCount`. Anthropic `output_tokens` and Ollama `eval_count` combine reasoning with other output, so they deliberately remain fallback-only.

- [ ] **Step 1: Write failing OpenAI accumulator tests**

  In `test/services/llm_service_test.dart`, add tests that feed `OpenAiStreamAccumulator.addData` an OpenAI-compatible final chunk containing:

  ```dart
  {
    'choices': [
      {'delta': {}, 'finish_reason': 'stop'},
    ],
    'usage': {
      'completion_tokens_details': {'reasoning_tokens': 37},
    },
  }
  ```

  Assert `accumulator.reasoningTokenCount == 37`. Add a second fixture with
  missing or non-integer `reasoning_tokens` and assert the value stays null.

- [ ] **Step 2: Run the focused test to verify RED**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: FAIL because `OpenAiStreamAccumulator` has no
  `reasoningTokenCount` property.

- [ ] **Step 3: Implement the smallest provider-neutral metadata extension**

  Add `final int? reasoningTokenCount` to `LlmStreamEvent` and the diagnostics
  factory. In `OpenAiStreamAccumulator.addData`, read only a non-negative int
  from `usage.completion_tokens_details.reasoning_tokens`, retain it, and pass
  it in the terminal diagnostics event from `_streamOpenAi`.

  In the Gemini stream parser, emit a diagnostics event only when its
  independent `usageMetadata.thoughtsTokenCount` is present:

  ```dart
  yield LlmStreamEvent.diagnostics(
    malformedEventCount: 0,
    reasoningTokenCount: exactReasoningTokens,
  );
  ```

  Do not treat Anthropic `message_delta.usage.output_tokens` or Ollama terminal
  `eval_count` as exact reasoning usage because each combines other output
  categories. Ignore absent, negative, and wrongly typed fields.

- [ ] **Step 4: Run the focused test to verify GREEN**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: PASS, including the exact and missing OpenAI usage cases.

- [ ] **Step 5: Commit the provider metadata slice**

  ```bash
  git add lib/services/llm_service.dart lib/services/llm_service_providers.dart test/services/llm_service_test.dart
  git commit -m "feat: expose reasoning token usage from streams"
  ```

### Task 2: Estimate, retain, and render reasoning token counts

**Files:**

- Modify: `lib/widgets/ai_assistant_panel_models.dart:32-134`
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart:5-174`
- Modify: `lib/widgets/ai_assistant_panel_content.dart:780-804`
- Modify: `lib/widgets/ai_assistant_panel_widgets.dart:234-310`
- Test: `test/services/llm_service_test.dart`

**Interfaces:**

- Produces `LlmService.estimateReasoningTokenCount(String reasoning) -> int`, returning a non-negative display estimate.
- Produces `_ChatMessage.reasoningTokenCount` and `_ChatMessage.hasExactReasoningTokenCount`.
- Consumes `LlmStreamEvent.reasoningTokenCount` and renders `_ReasoningSection(reasoning:, tokenCount:, isExactTokenCount:)`.

- [ ] **Step 1: Write failing estimator and card tests**

  In `test/services/llm_service_test.dart`, add tests for the public estimator:

  ```dart
  expect(LlmService.estimateReasoningTokenCount('one two three four'), 4);
  expect(
    LlmService.estimateReasoningTokenCount('先检查连接，然后执行命令。'),
    greaterThan(0),
  );
  ```

  Also add direct tests for the public
  `LlmService.reasoningTokenCountLabel(tokenCount: 12, isExact: false)` and
  `isExact: true`, expecting `约 12 tokens` and `12 tokens` respectively.

- [ ] **Step 2: Run the focused test to verify RED**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: FAIL because the estimator and token-label formatter do not exist.

- [ ] **Step 3: Implement the smallest panel state and UI change**

  Add the two public pure helpers to `LlmService`, then add nullable
  token-count state to `_ChatMessage`. Add a deterministic,
  Unicode-safe estimate that counts whitespace-separated Latin runs and CJK
  code points without returning zero for non-empty reasoning. During existing
  scheduled refreshes, set the message's estimate only until an exact count is
  received. On a diagnostics event with a non-null count, store it and mark it
  exact; do not replace it with later estimates.

  Pass the state into `_ReasoningSection`. Place a small header label beside
  the existing thinking title: `约 N tokens` for fallback values and `N tokens`
  for exact usage. Do not render a label when the message has no reasoning.

- [ ] **Step 4: Run the focused test to verify GREEN**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: PASS with exact and estimated labels plus the Chinese fallback case.

- [ ] **Step 5: Commit the panel slice**

  ```bash
  git add lib/services/llm_service.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_tooling.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/services/llm_service_test.dart
  git commit -m "feat: display agent reasoning token counts"
  ```

### Task 3: Verify the integrated behavior

**Files:**

- Modify: only files from Tasks 1-2 when formatter output requires it.

- [ ] **Step 1: Format the changed Dart sources and tests**

  Run:

  ```bash
  dart format lib/services/llm_service.dart lib/services/llm_service_providers.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_tooling.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/services/llm_service_test.dart
  ```

- [ ] **Step 2: Run static analysis**

  Run: `flutter analyze`

  Expected: exit code 0 and no diagnostics.

- [ ] **Step 3: Run the complete test suite**

  Run: `flutter test`

  Expected: exit code 0 and no test failures.

- [ ] **Step 4: Inspect the final patch before handoff**

  Run: `git diff --check && git status --short`

  Expected: no whitespace errors and only the intended feature files changed.

- [ ] **Step 5: Commit verified integration work**

  ```bash
  git add lib/services/llm_service.dart lib/services/llm_service_providers.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_tooling.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/services/llm_service_test.dart
  git commit -m "test: cover reasoning token count display"
  ```
