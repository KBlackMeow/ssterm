# Native Tool-call Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each native provider tool call and sanitized arguments in the agent chat before it executes.

**Architecture:** Store display-only native calls in `_ChatMessage` and render them with a dedicated expandable card. Keep formatting/redaction in a pure helper so UI and execution remain decoupled.

**Tech Stack:** Flutter/Dart, existing assistant-panel chat models and widgets, `flutter_test`.

## Global Constraints

- Do not alter provider payloads, call ordering, confirmation policy, or MCP execution.
- Redact keys containing `token`, `password`, `secret`, `api_key`, or `authorization`, case-insensitively.
- Truncate displayed argument values after 2,000 characters with a visible suffix.

---

### Task 1: Tool-call display data and formatter

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Test: `test/widgets/ai_assistant_panel_models_test.dart`

**Interfaces:**
- Produces `_ToolCallData` with `summary` and `formattedArgumentsFor(ToolCall)`.
- Consumes `ToolCall` from `lib/services/llm_service.dart`.

- [ ] **Step 1: Write failing formatter tests**

```dart
expect(_ToolCallData.formatArguments({'api_key': 'secret'}), contains('[redacted]'));
expect(_ToolCallData.fromCalls(calls).summary, 'Calling 2 tools');
```

- [ ] **Step 2: Run the focused test**

Run: `flutter test test/widgets/ai_assistant_panel_models_test.dart`

- [ ] **Step 3: Implement immutable display payload and recursive sanitizer**

```dart
class _ToolCallData {
  final List<ToolCall> calls;
  String get summary => calls.length == 1 ? 'Calling ${calls.single.name}' : 'Calling ${calls.length} tools';
  static String formatArguments(Map<String, Object?> arguments) { /* redact then JSON pretty-print */ }
}
```

- [ ] **Step 4: Re-run focused test**

Run: `flutter test test/widgets/ai_assistant_panel_models_test.dart`

### Task 2: Persist and render tool-call cards

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`

**Interfaces:**
- Consumes `_ChatMessage.toolCalls(_ToolCallData)`.
- Produces `_ToolCallCard` as an informational expandable card.

- [ ] **Step 1: Add a failing widget assertion for the collapsed card**

```dart
expect(find.text('Calling 2 tools'), findsOneWidget);
```

- [ ] **Step 2: Add `_ChatMessage.toolCalls` and append it before tool dispatch**

```dart
_messages.add(_ChatMessage.toolCalls(toolCalls));
```

- [ ] **Step 3: Render `_ToolCallCard` before MCP result cards**

```dart
ExpansionTile(title: Text(data.summary), children: [...data.calls.map(_buildCallRow)])
```

- [ ] **Step 4: Run focused widget test**

Run: `flutter test test/widgets/ai_assistant_panel_models_test.dart`

### Task 3: Regression verification

**Files:**
- Test: `test/widgets/ai_assistant_panel_models_test.dart`

- [ ] **Step 1: Cover nested redaction and 2,000-character truncation**
- [ ] **Step 2: Run `flutter analyze` on modified panel files**
- [ ] **Step 3: Run focused agent protocol and widget tests**

Run:

```sh
flutter test test/services/agent_tool_contract_test.dart test/services/agent_provider_tools_test.dart test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart test/widgets/ai_assistant_panel_models_test.dart
```
