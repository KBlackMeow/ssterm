# Agent Chat Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Agent1 and Agent2 conversation history selectable and copyable through Flutter's platform selection controls.

**Architecture:** Wrap the populated chat `ListView.builder` in one `SelectionArea`. Because both agents instantiate `AiAssistantOverlay`, the shared change covers both without an Agent2-specific flag.

**Tech Stack:** Dart, Flutter, `flutter_test`

## Global Constraints

- Do not add copy buttons or change persisted message content.
- Keep the input field and empty state outside the transcript selection area.
- Preserve existing scrolling and nested `SelectableText` behavior.

---

### Task 1: Selectable conversation viewport

**Files:**
- Create: `test/widgets/ai_assistant_panel_selection_test.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart:282-299`

**Interfaces:**
- Consumes: public `AiAssistantOverlay`, `AiPanelMode.agent`, and its existing send flow.
- Produces: a `SelectionArea` ancestor for the populated transcript `ListView`.

- [ ] **Step 1: Write the failing widget test**

Build a visible `AiAssistantOverlay` in Agent mode, enter `copy me` into its
`TextField`, tap `Icons.send_rounded`, pump once, and assert:

```dart
expect(find.text('copy me'), findsOneWidget);
expect(
  find.ancestor(
    of: find.byType(ListView),
    matching: find.byType(SelectionArea),
  ),
  findsOneWidget,
);
```

- [ ] **Step 2: Run the test and verify RED**

```bash
flutter test test/widgets/ai_assistant_panel_selection_test.dart
```

Expected: FAIL because no `SelectionArea` is present.

- [ ] **Step 3: Wrap only the populated conversation list**

Change the non-empty branch to:

```dart
SelectionArea(
  child: ListView.builder(
    controller: scrollController,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    itemCount: messages.length + (loopStatus != null ? 1 : 0),
    itemBuilder: (ctx, i) {
      if (loopStatus != null && i == messages.length) {
        return _loopStatusIndicator(context, loopStatus!);
      }
      return _buildAgentMessage(ctx, messages[i]);
    },
  ),
)
```

- [ ] **Step 4: Run focused verification**

```bash
flutter test test/widgets/ai_assistant_panel_selection_test.dart test/widgets/agent_panel_layout_invariants_test.dart
dart analyze lib/widgets/ai_assistant_panel_content.dart test/widgets/ai_assistant_panel_selection_test.dart
```

Expected: all tests PASS and analysis reports no issues.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel_content.dart test/widgets/ai_assistant_panel_selection_test.dart
git commit -m "feat: make agent chat history selectable"
```

