# Stream Adaptive Decision Deliberation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream planner and reviewer content into normal assistant messages before parsing their final decision data.

**Architecture:** Add a reusable `AgentDeliberation.streamPlan` / `streamCritique` path that consumes `LlmService.chatStream`, emits text chunks through a callback, and returns the parsed final value plus usage. The panel owns the temporary assistant messages and updates them as chunks arrive; on success it replaces their text with `AgentDecisionTranscript` summaries.

**Tech Stack:** Flutter/Dart, `LlmService.chatStream`, `AgentStreamClientSession`, `flutter_test`.

## Global Constraints

- Planner and reviewer remain tool-free.
- Hide reasoning events and internal prompts.
- Do not add client-only progress messages to `_conversationHistory`.
- Preserve cancellation and fallback behavior.

---

### Task 1: Streamed deliberation service

**Files:**
- Modify: `lib/services/agent_deliberation.dart`
- Modify: `test/services/agent_deliberation_test.dart`

**Interfaces:**
- Produces `streamPlan` and `streamCritique`, accepting an `AgentStreamClientSession` and `void Function(String) onText` callback.
- Returns `AgentDeliberationResult<AgentDecisionPlan>` with parsed plan and diagnostics usage.

- [ ] **Step 1: Write failing tests for stream-event accumulation and final parsing.**
- [ ] **Step 2: Run `flutter test test/services/agent_deliberation_test.dart` and observe failure.**
- [ ] **Step 3: Implement one private stream collector that forwards only text chunks, accumulates diagnostics usage, and parses after completion.**
- [ ] **Step 4: Re-run the service tests and commit.**

### Task 2: Stream the visible planning and review messages

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- Consumes the new streamed deliberation methods.
- Produces temporary `_ChatMessage.ai` objects updated on each callback, then replaced by `AgentDecisionTranscript` text after a successful parse.

- [ ] **Step 1: Add failing coverage for `streamPlan`, `streamCritique`, and streamed-message updates.**
- [ ] **Step 2: Run the selected widget test and observe failure.**
- [ ] **Step 3: Replace non-streaming `plan`/`critique` awaits with streamed calls using isolated sessions and callback-driven `setState`.**
- [ ] **Step 4: Run selected service/widget tests, analyzer, and full `flutter test`.**
- [ ] **Step 5: Commit and integrate after verification.**
