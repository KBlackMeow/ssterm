# Agent Clear Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a header button that clears the current Agent conversation using the existing clear path.

**Architecture:** `_AiPanelContent` receives an `onClear` callback from
`_AiAssistantOverlayState._clearChat` and passes it to `_AgentHeader`. The
header renders a compact tooltip-wrapped icon alongside its existing dock
toggle; no clear logic is duplicated.

**Tech Stack:** Flutter, Dart, flutter_test.

## Global Constraints

- The button must call the existing `_clearChat` method.
- Clear must cancel active Agent work and clear both visible and LLM history.
- No terminal command-injection path may be introduced.

---

### Task 1: Wire the Agent header clear callback

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart:496-522`
- Modify: `lib/widgets/ai_assistant_panel_content.dart:15-41,196`
- Modify: `lib/widgets/ai_assistant_panel_widgets.dart:17-55`
- Test: `test/app/agent_wiring_source_test.dart`

**Interfaces:**
- Consumes: `_AiAssistantOverlayState._clearChat()`.
- Produces: `_AiPanelContent.onClear` and `_AgentHeader.onClear`, both
  `VoidCallback` values.

- [ ] **Step 1: Write the failing source-wiring test**

```dart
test('Agent header exposes the existing clear-chat action', () {
  final panel = File('lib/widgets/ai_assistant_panel.dart').readAsStringSync();
  final content = File('lib/widgets/ai_assistant_panel_content.dart').readAsStringSync();
  final widgets = File('lib/widgets/ai_assistant_panel_widgets.dart').readAsStringSync();

  expect(panel, contains('onClear: _clearChat'));
  expect(content, contains('required this.onClear'));
  expect(content, contains('onClear: onClear'));
  expect(widgets, contains('final VoidCallback onClear'));
  expect(widgets, contains("message: 'Clear conversation'"));
});
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `flutter test test/app/agent_wiring_source_test.dart`

Expected: FAIL because `onClear` has not been wired.

- [ ] **Step 3: Implement the callback wiring and icon**

```dart
// ai_assistant_panel.dart
onClear: _clearChat,

// ai_assistant_panel_content.dart
required this.onClear,
final VoidCallback onClear;
_AgentHeader(position: position, onClear: onClear, onPositionToggle: onPositionToggle),

// ai_assistant_panel_widgets.dart
final VoidCallback onClear;
Tooltip(
  message: 'Clear conversation',
  child: InkWell(
    onTap: onClear,
    child: const Padding(
      padding: EdgeInsets.all(4),
      child: Icon(Icons.delete_outline, size: 14),
    ),
  ),
),
```

- [ ] **Step 4: Run focused tests and static analysis**

Run: `flutter test test/app/agent_wiring_source_test.dart && flutter analyze lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/app/agent_wiring_source_test.dart`

Expected: PASS with no analyzer issues.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/app/agent_wiring_source_test.dart
git commit -m "feat: add Agent conversation clear button"
```
