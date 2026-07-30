# Native Tool Calling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SSTerm use provider-native tool calling for OpenAI, Anthropic, and Gemini while preserving the existing fenced-JSON protocol as a fallback for Ollama and unsupported endpoints.

**Architecture:** Introduce provider-neutral request and response models for tool definitions and tool invocations. Provider adapters translate them to native wire formats; the existing agent loop consumes one normalized `ToolCall` representation. The system prompt becomes a short policy prompt, while executable schemas move to provider `tools` fields.

**Tech Stack:** Flutter/Dart, `dart:io` HTTP/SSE, OpenAI-compatible Chat Completions, Anthropic Messages, Gemini generateContent.

## Global Constraints

- Preserve all existing user-facing tool behaviors: confirmation cards, file Apply/Reject, MCP execution, and legacy markdown parsing.
- Treat tool definitions and tool results as data; no provider response may bypass executor safety checks.
- Keep Ollama on the legacy textual protocol for this iteration.
- One executable tool call per model turn for native providers; enforce this in request settings where supported and in the executor everywhere.
- Do not add third-party dependencies.

---

### Task 1: Provider-neutral native tool contract

**Files:**
- Create: `lib/services/agent_tool_contract.dart`
- Modify: `lib/services/llm_service.dart`
- Test: `test/services/agent_tool_contract_test.dart`

**Interfaces:**
- Produces `AgentToolDefinition`, `AgentToolCall`, and `AgentToolResponse`.
- `AgentToolDefinition.toJsonSchema()` returns the provider-neutral parameter schema map.
- `AgentToolResponse` keeps visible text and normalized calls separate.

- [ ] Write failing tests for a `bash` definition, a file-write definition, and normalization of a native call with JSON-object arguments.
- [ ] Run `flutter test test/services/agent_tool_contract_test.dart`; verify the missing contract types cause compilation failure.
- [ ] Implement immutable contract types with input validation and JSON-object argument normalization.
- [ ] Run the focused test file; verify all cases pass.

### Task 2: Canonical SSTerm tool registry

**Files:**
- Create: `lib/services/agent_tool_registry.dart`
- Modify: `lib/services/llm_service.dart`
- Test: `test/services/agent_tool_registry_test.dart`

**Interfaces:**
- Consumes `AgentConfig`, `McpService.allTools`, and enabled skill ids.
- Produces `AgentToolRegistry.build(config)` with `coreTools`, optional tools, and a bounded MCP list.
- `forNativeProvider` exposes JSON-schema definitions; `legacyPromptHints` exposes only compatibility hints.

- [ ] Write failing tests that disabled capabilities are absent and enabled web/file tools emit schemas with required fields.
- [ ] Run the focused test file and verify failure before implementation.
- [ ] Implement the registry with fixed schemas for bash, ask_user_question, web_search, write_file, edit_file, use_skill, and a bounded MCP wrapper schema.
- [ ] Run focused tests and the existing `llm_service_test.dart` suite.

### Task 3: OpenAI-compatible native tool adapter

**Files:**
- Modify: `lib/services/llm_service.dart`
- Modify: `lib/services/llm_service_providers.dart`
- Test: `test/services/llm_service_test.dart`

**Interfaces:**
- `LlmResponse` gains `toolCalls` while retaining `text`.
- OpenAI-compatible payloads include `tools`, `tool_choice: auto`, and `parallel_tool_calls: false` only for the OpenAI provider.
- Native `message.tool_calls` returns normalized calls.

- [ ] Add failing parser tests for a Chat Completions `tool_calls` response and for malformed arguments being ignored safely.
- [ ] Run focused tests; verify the new native parser is absent.
- [ ] Add payload construction and response normalization without changing DeepSeek defaults yet.
- [ ] Run focused tests and all service tests.

### Task 4: Anthropic and Gemini native tool adapters

**Files:**
- Modify: `lib/services/llm_service_providers.dart`
- Test: `test/services/llm_service_test.dart`

**Interfaces:**
- Anthropic sends `tools: [{name, description, input_schema}]` and parses `tool_use` blocks.
- Gemini sends `tools: [{functionDeclarations: [...]}]` and parses `functionCall` parts.
- Both produce the Task 1 normalized calls.

- [ ] Add failing fixture-parser tests for Anthropic `tool_use` and Gemini `functionCall` payloads.
- [ ] Run focused tests and verify failure.
- [ ] Implement provider serializers and normalizers, retaining current text/reasoning stream behavior.
- [ ] Run all `llm_service_test.dart` tests and `flutter analyze`.

### Task 5: Agent-loop integration and legacy fallback

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart`
- Modify: `lib/services/llm_service_prompts.dart`
- Test: `test/services/llm_service_test.dart`
- Test: `test/widgets/ai_assistant_panel_test.dart` (create if existing widget coverage cannot host loop behavior)

**Interfaces:**
- The stream collector returns both visible text and native calls.
- Loop uses native calls when provided; otherwise calls `LlmService.extractToolCalls(visibleText)`.
- Legacy system prompt retains only fallback protocol instructions; native system prompt has no schema examples or marker requirements.

- [ ] Write a failing loop-level test proving a native `write_file` invocation reaches the existing Apply flow without requiring a fenced JSON block.
- [ ] Run the test and verify failure.
- [ ] Pass native calls through the stream collector and reuse the existing executor branches.
- [ ] Keep legacy extraction as an explicit fallback path, then remove redundant native-tool schema blocks from the native prompt profile.
- [ ] Run focused widget/service tests, full `flutter test`, and `flutter analyze`.

### Task 6: Token-budgeted context and observability

**Files:**
- Create: `lib/services/agent_context_budget.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/services/command_feedback_formatter.dart`
- Test: `test/services/agent_context_budget_test.dart`

**Interfaces:**
- `AgentContextBudget.compact(messages)` returns a role-valid, token-estimated history.
- It pins goal/session state, keeps the newest raw result turns, and replaces older tool results with an explicit summary envelope.

- [ ] Write failing tests for bounded histories, pinned first user goal, and preservation of the latest tool result.
- [ ] Run focused tests and verify failure.
- [ ] Implement deterministic character-based budgeting with a conservative token estimate and summary envelopes.
- [ ] Add logs for estimated input budget, native-vs-legacy calls, and tool-call validity.
- [ ] Run full test and analysis suites.

### Task 7: Evaluation fixtures and rollout controls

**Files:**
- Create: `test/fixtures/agent_eval_cases.json`
- Create: `test/services/agent_eval_test.dart`
- Modify: `README.md`

**Interfaces:**
- Fixture cases define configuration, initial user prompt, expected tool name, and expected no-tool outcome.
- Test reports tool schema validity and tool-selection assertions deterministically from recorded provider fixtures.

- [ ] Add failing fixtures for shell inspection, file edit, user clarification, MCP request, and plain final answer.
- [ ] Implement a deterministic fixture runner over the normalizers and registry.
- [ ] Document native-tool capability, fallback behavior, and metrics.
- [ ] Run `flutter test` and `flutter analyze` before handoff.
