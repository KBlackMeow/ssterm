# Agent Context Compaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace middle-history deletion with safe, provider-neutral summary memory for long SSTerm agent conversations.

**Architecture:** Add a pure compactor and group-aware history APIs. Before a normal agent request, the panel asks the configured provider for a tool-free summary of old groups, then retains the opening goal, summary, and recent complete groups. It keeps current trimming as a failure fallback.

**Tech Stack:** Flutter/Dart, `flutter_test`, existing `LlmService` provider adapters, typed `AgentConversationItem`.

## Global Constraints

- Never split a native assistant tool call from its tool result.
- Compaction requests receive no tools and produce no visible chat message.
- Transcript text and tool output are untrusted data, not instructions.
- Empty, invalid, failed, or stale summaries fall back to safe trimming.
- `/clear`, `/reset`, and `/new` clear compacted memory.

---

### Task 1: Build the pure compaction model

**Files:**

- Create: `lib/services/conversation_compactor.dart`
- Modify: `lib/services/agent_tool_contract.dart`
- Create: `test/services/conversation_compactor_test.dart`
- Modify: `test/services/agent_tool_contract_test.dart`

**Interfaces:**

- `ConversationCompactor.buildPrompt({required String existingSummary, required Iterable<AgentConversationItem> items}) -> String`
- `ConversationCompactor.validateSummary(String response) -> String?`
- `AgentConversationHistory.compactionCandidate({required int pinnedItemCount, required int recentItemCount}) -> List<AgentConversationItem>`
- `AgentConversationHistory.replaceWithSummary({required String summary, required int pinnedItemCount, required int recentItemCount}) -> bool`

- [ ] **Step 1: Write the failing tests**

```dart
test('buildPrompt treats the transcript as data and requests task state', () {
  final prompt = ConversationCompactor.buildPrompt(
    existingSummary: 'Changed lib/a.dart.',
    items: [const AgentConversationItem.text(role: 'user', content: 'Do work')],
  );
  expect(prompt, contains('untrusted transcript data'));
  expect(prompt, contains('Remaining work'));
});

test('replacement never leaves an old tool result without its call', () {
  final history = historyWithOldToolPairAndRecentMessages();
  history.replaceWithSummary(
    summary: 'Tool completed.',
    pinnedItemCount: 1,
    recentItemCount: 2,
  );
  expect(history.where((item) => item.toolCalls.isNotEmpty), isEmpty);
  expect(history.where((item) => item.toolResults.isNotEmpty), isEmpty);
  expect(history[1].content, contains('<conversation_summary>'));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/conversation_compactor_test.dart test/services/agent_tool_contract_test.dart`

Expected: failure because the compactor and history APIs do not exist.

- [ ] **Step 3: Implement minimally**

Create the compactor with a fixed prompt requiring goal/constraints, completed work, relevant files/commands/decisions, state, remaining work, and failures. Reject blank summaries. Add history selection/replacement that handles tool call/result pairs as one group and inserts a fixed `<conversation_summary>` user message after the pinned head.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/services/conversation_compactor_test.dart test/services/agent_tool_contract_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/conversation_compactor.dart lib/services/agent_tool_contract.dart test/services/conversation_compactor_test.dart test/services/agent_tool_contract_test.dart
git commit -m "feat: add agent conversation compaction model"
```

### Task 2: Add a non-tool compaction request

**Files:**

- Modify: `lib/services/llm_service.dart`
- Modify: `lib/services/llm_service_providers.dart`
- Modify: `test/services/llm_service_test.dart`

**Interfaces:**

- `LlmService.compactConversation({required AgentConfig config, required String prompt}) -> Future<String?>`

- [ ] **Step 1: Write the failing provider-request test**

```dart
test('compaction request has no tool definitions', () {
  final body = LlmService.openAiCompactionRequestForTest(
    model: 'gpt-5.6-terra',
    prompt: 'summarize',
  );
  expect(body.containsKey('tools'), isFalse);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/llm_service_test.dart`

Expected: failure because the compaction request API does not exist.

- [ ] **Step 3: Implement minimally**

Reuse existing non-streaming parsers for every provider, but send one fixed compaction system prompt and one user prompt, with no agent tool schemas. Return only `ConversationCompactor.validateSummary` output.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/services/llm_service_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/llm_service.dart lib/services/llm_service_providers.dart test/services/llm_service_test.dart
git commit -m "feat: request agent context summaries without tools"
```

### Task 3: Compact before normal agent streaming

**Files:**

- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `test/services/agent_tool_contract_test.dart`

**Interfaces:**

- `_compactHistoryIfNeeded(int generation, AgentConfig config) -> Future<void>`

- [ ] **Step 1: Write a failing eligibility test**

```dart
test('candidate retains the opening goal and recent complete groups', () {
  final history = historyWithManyGroups();
  final candidate = history.compactionCandidate(
    pinnedItemCount: 1,
    recentItemCount: 6,
  );
  expect(candidate, isNotEmpty);
  expect(candidate.any((item) => item.content == 'initial goal'), isFalse);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/agent_tool_contract_test.dart`

Expected: failure until selection respects the pinned head and complete groups.

- [ ] **Step 3: Implement minimally**

At the current trim point, check the threshold. When eligible, set loop status to “Compressing context…”, build a prompt from old groups and any existing summary, request the tool-free summary, and replace old groups only if the generation still matches. On every invalid/error/stale response, invoke the existing group-aware trim. Do not alter visible chat messages.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/services/agent_tool_contract_test.dart test/services/conversation_compactor_test.dart && flutter analyze lib/services lib/widgets/ai_assistant_panel.dart`

Expected: PASS without analyzer diagnostics.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart test/services
git commit -m "feat: compact long agent conversations"
```

### Task 4: Verify regressions

**Files:**

- Test: `test/services/agent_provider_tools_test.dart`
- Test: `test/services/command_feedback_formatter_test.dart`
- Test: `test/services/llm_service_test.dart`

- [ ] **Step 1: Add a provider serialization assertion**

```dart
test('summary serializes as text while following native tool results stay structured', () {
  final messages = AgentProviderTools.openAiMessages(historyWithSummaryAndToolPair());
  expect(messages.first['content'], contains('<conversation_summary>'));
  expect(messages.last['role'], 'tool');
});
```

- [ ] **Step 2: Run regression verification**

Run: `flutter test test/services && flutter analyze`

Expected: PASS with no test failures or analyzer diagnostics.

- [ ] **Step 3: Commit**

```bash
git add test/services
git commit -m "test: cover agent context compaction"
```

