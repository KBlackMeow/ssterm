# Agent 自适应上下文压缩实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Replace count-based Agent compaction with model-window token budgets and safe fallback behavior.

**Architecture:** Add a pure context-budget service that calculates thresholds and estimates typed history. Extend model configuration with an optional context window. Provider adapters surface normalized usage when available; the agent loop uses exact usage first, estimates otherwise, and preserves complete tool groups during compression.

**Tech Stack:** Dart, Flutter test, existing LLM provider adapters.

## Global Constraints

- Unknown/custom/Ollama models default to a 32K window and 16K compaction point.
- Known models compact at window minus summary reserve minus 12K.
- Maximum automatic summary reserve is 16K and minimum is 4K.
- Never split native tool calls from their results.
- Context-overflow recovery retries exactly once.
- Existing persisted AgentConfig remains valid.

---

### Task 1: Add model context-window persistence

**Files:**
- Modify: lib/models/agent_config.dart
- Modify: test/models/agent_config_test.dart

- [ ] Write failing JSON round-trip tests for nullable contextWindowTokens and old JSON without it.
- [ ] Add nullable int contextWindowTokens to ProviderConfig model entries, serialize only positive values, and preserve null for old settings.
- [ ] Populate built-in cloud models through a model-capability lookup instead of assuming every string is 200K.
- [ ] Run: flutter test test/models/agent_config_test.dart
- [ ] Commit: feat: persist model context window

### Task 2: Add pure token budget and typed-history estimator

**Files:**
- Create: lib/services/agent_context_budget.dart
- Create: test/services/agent_context_budget_test.dart
- Modify: lib/services/agent_tool_contract.dart

- [ ] Write failing tests for 32K unknown -> 16K, 64K -> 40K, 128K -> 100K, 200K -> 172K, and 80-item fallback.
- [ ] Implement AgentContextBudget with contextWindowTokens, summaryReserveTokens, autoCompactAtTokens, hardLimitTokens, and shouldCompact.
- [ ] Add a UTF-8 conservative token estimator for AgentConversationItem text, native tool calls, and tool results; do not count visible-only cards.
- [ ] Add a history method that returns estimated token count without mutating item order.
- [ ] Run: flutter test test/services/agent_context_budget_test.dart test/services/conversation_compactor_test.dart
- [ ] Commit: feat: add agent context token budgets

### Task 3: Surface normalized provider usage

**Files:**
- Modify: lib/services/llm_service.dart
- Modify: lib/services/llm_service_providers.dart
- Modify provider adapter tests under test/services/llm_service_test.dart

- [ ] Write failing stream-event tests showing input, cached input, and output usage survive provider normalization.
- [ ] Add nullable LlmTokenUsage(inputTokens, cachedInputTokens, outputTokens) to diagnostics events.
- [ ] Map provider response usage fields where each provider exposes them; retain null where unavailable.
- [ ] Run focused provider tests.
- [ ] Commit: feat: surface agent context usage

### Task 4: Replace fixed count compaction in the agent loop

**Files:**
- Modify: lib/widgets/ai_assistant_panel.dart
- Modify: lib/widgets/ai_assistant_panel_loop.dart
- Modify: test/services/conversation_compactor_test.dart

- [ ] Write failing tests for exact usage taking precedence over estimator and for 80-item fallback only when usage is absent.
- [ ] Remove _maxHistoryTurns and _recentHistoryItems count thresholds. Store latest normalized usage for the current conversation.
- [ ] Before each request, compute budget from selected model and run compaction only when budget requires it. Derive the retained tail by token budget while preserving complete tool pairs.
- [ ] On provider context-overflow, compact once and retry the original request; surface the second failure without looping.
- [ ] Run focused conversation tests.
- [ ] Commit: feat: use token budgets for agent compaction

### Task 5: Complete verification

**Files:**
- Modify: relevant tests only if coverage gaps remain.

- [ ] Run: flutter test
- [ ] Run: flutter analyze
- [ ] Run: git diff --check
- [ ] Commit final test coverage if required.

