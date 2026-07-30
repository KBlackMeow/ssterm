# Native Tool Result State Machine Implementation Plan

> **For agentic workers:** Execute inline in this session; the user explicitly requested implementation and this workspace has a dirty shared worktree.

**Goal:** Preserve native tool calls and tool results across agent iterations, serialize them in each provider's required wire format, and avoid treating a plain post-tool response as verified task completion.

**Architecture:** Add provider-neutral conversation items for text, assistant tool calls, and tool results. The panel owns the conversation list and appends real execution outcomes. Provider adapters serialize the same items to OpenAI-compatible Chat Completions, Anthropic Messages, and Gemini GenerateContent shapes. The loop accepts a text-only reply as a candidate final response, while action tasks require a verified postcondition or an explicit structured completion event.

**Tech Stack:** Flutter/Dart, `dart:io` HTTP/SSE, OpenAI-compatible Chat Completions, Anthropic Messages, Gemini GenerateContent, MCP.

## Global Constraints

- Preserve existing shell confirmations, file Apply/Reject cards, MCP execution, and Ollama textual fallback.
- Do not expose tool arguments or tool-result content in debug logs.
- Do not drop provider-returned tool calls; queue or reject them with an explicit result.
- Keep agent loops bounded by `_maxLoopIterations`.

---

### Task 1: Provider-neutral native conversation contract

**Files:**
- Modify: `lib/services/agent_tool_contract.dart`
- Test: `test/services/agent_tool_contract_test.dart`

**Interfaces:**
- Add `AgentConversationItem.text`, `.assistantToolCalls`, and `.toolResults`.
- A tool result retains `toolCallId`, result text, and `isError`.

- [ ] Write failing tests for a call/result pair preserving IDs and error state.
- [ ] Run `flutter test test/services/agent_tool_contract_test.dart` and verify compilation fails before implementation.
- [ ] Implement immutable conversation item types.
- [ ] Re-run the focused test and verify it passes.

### Task 2: Provider serializers

**Files:**
- Modify: `lib/services/agent_provider_tools.dart`
- Modify: `lib/services/llm_service_providers.dart`
- Test: `test/services/agent_provider_tools_test.dart`

**Interfaces:**
- OpenAI emits an assistant `tool_calls` message followed by `role: tool` messages with `tool_call_id`.
- Anthropic emits assistant `tool_use` blocks followed immediately by user `tool_result` blocks.
- Gemini emits model `functionCall` parts followed by user `functionResponse` parts.

- [ ] Write failing payload tests for one `mcp__matrix__file_upload` call and error result for each provider.
- [ ] Run the focused provider test and verify failure.
- [ ] Implement provider payload serializers and route all native provider request bodies through them.
- [ ] Run focused provider tests and `test/services/llm_service_test.dart`.

### Task 3: Panel-owned native transcript and queued execution

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart`
- Test: `test/services/agent_tool_contract_test.dart` and existing service tests

**Interfaces:**
- `_conversationHistory` becomes `List<AgentConversationItem>`.
- Tool-call assistant items and corresponding result items are appended as a pair.
- Multiple returned calls are queued; mutable MCP and shell calls remain serial and preserve order.

- [ ] Write a failing contract test that queues multiple calls without dropping IDs.
- [ ] Run the focused test and verify failure.
- [ ] Replace text-only transcript appends with typed text/tool-call/tool-result appends.
- [ ] Remove the temporary `limitToolCallsToOne` drop policy.
- [ ] Run focused tests and static analysis.

### Task 4: Completion policy and observability

**Files:**
- Modify: `lib/services/llm_service_prompts.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Test: `test/services/llm_service_test.dart`

**Interfaces:**
- Native prompt asks for an explicit completion decision only when an action task has a verified result.
- A plain answer after a tool result is logged as a candidate final response, not falsely described as successful execution.
- Upload success requires the MCP result to return a non-error artifact reference before it is reported as completed.

- [ ] Write failing tests for completion-decision classification.
- [ ] Run the focused test and verify failure.
- [ ] Add bounded continuation/error behavior and stop-reason logs.
- [ ] Run focused tests and full test suite, reporting the existing WSL PATH failure separately.
