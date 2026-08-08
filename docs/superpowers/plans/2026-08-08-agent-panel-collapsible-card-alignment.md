# Agent Panel Collapsible Card Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Align top-level command-result and tool-call collapsible cards to the Agent transcript's left edge.

**Architecture:** The two cards are wrapped by _buildAgentMessage in the same list that already supplies 16px horizontal padding. Remove only their extra left padding; all card internals and assistant-message layout stay unchanged.

**Tech Stack:** Flutter/Dart, Flutter widget test suite.

## Global Constraints

- Modify only the outer wrappers of CommandResultCard and ToolCallCard.
- Preserve internal card padding and expansion behavior.
- Keep reasoning and edit-diff folding in their current nested alignment.
- Do not change MCP result, confirmations, ordinary messages, or input layout.

---

### Task 1: Remove outer collapsible-card indentation

**Files:**
- Modify: lib/widgets/ai_assistant_panel_content.dart:588-701
- Test: test/widgets/ai_assistant_panel_test.dart if a public overlay layout harness exists

**Interfaces:**
- Consumes: the transcript ListView horizontal padding of EdgeInsets.fromLTRB(16, 8, 16, 8).
- Produces: CommandResultCard and ToolCallCard outer wrappers with no left padding.

- [ ] **Step 1: Add or identify a layout regression assertion**

Use the existing public AiAssistantOverlay test harness if present. Render one command-result and one native-tool-call message, then assert each card's RenderBox x-coordinate equals the transcript content x-coordinate. If these private message shapes cannot be reached through public APIs, record the source-level invariant in the focused panel test instead: the two wrappers use EdgeInsets.only(bottom: ...), without a left argument.

- [ ] **Step 2: Run the assertion before the implementation**

Run: flutter test test/widgets/ai_assistant_panel_test.dart

Expected: FAIL because the two wrappers set left: 32.

- [ ] **Step 3: Apply the minimal layout change**

Replace:

```dart
padding: const EdgeInsets.only(bottom: 8, left: 32)
padding: const EdgeInsets.only(bottom: 12, left: 32)
```

with:

```dart
padding: const EdgeInsets.only(bottom: 8)
padding: const EdgeInsets.only(bottom: 12)
```

Only do this for the CommandResultCard and ToolCallCard branches.

- [ ] **Step 4: Verify focused UI tests**

Run: flutter test test/widgets/ai_assistant_panel_test.dart

Expected: PASS.

- [ ] **Step 5: Verify all tests and commit**

Run: flutter test && git diff --check

Expected: all tests pass.

```bash
git add lib/widgets/ai_assistant_panel_content.dart test/widgets/ai_assistant_panel_test.dart
git commit -m "fix: left-align collapsible agent cards"
```

