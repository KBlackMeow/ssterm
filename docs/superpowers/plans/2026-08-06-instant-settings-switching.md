# Instant Settings Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make settings content switch instantly so it matches the vertical desktop rail.

**Architecture:** `SettingsConsoleShell` continues to own layout breakpoints and navigation input. It will select a single indexed child with `IndexedStack` instead of displaying a swipe-enabled `TabBarView`; the shared `TabController` remains the source of truth.

**Tech Stack:** Flutter, `flutter_test`.

## Global Constraints

- Keep all navigation destinations and controller selection behaviour.
- Disable horizontal swipe/page animation in both desktop and narrow layouts.
- Do not alter settings data, callbacks, or persistence.
- Do not commit changes, per user request.

---

### Task 1: Switch settings content without a horizontal transition

**Files:**
- Modify: `lib/views/settings/settings_console_shell.dart`
- Modify: `lib/views/settings/settings_sheet.dart`
- Test: `test/views/settings_console_shell_test.dart`

**Interfaces:**
- Consumes: existing `TabController`, `tabViews`, and rail selection callback.
- Produces: instant controller-indexed content replacement.

- [ ] **Step 1: Write the failing test**

```dart
testWidgets('rail selection replaces content without a TabBarView', (tester) async {
  await tester.pumpWidget(const _Harness(width: 1100));
  expect(find.byType(TabBarView), findsNothing);
  await tester.tap(find.text('Agent'));
  await tester.pump();
  expect(find.text('Agent content'), findsOneWidget);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/views/settings_console_shell_test.dart --plain-name "rail selection replaces content without a TabBarView"`

Expected: FAIL because `TabBarView` is still present.

- [ ] **Step 3: Implement the indexed content panel**

```dart
AnimatedBuilder(
  animation: controller,
  builder: (_, _) => IndexedStack(
    index: controller.index,
    children: tabViews,
  ),
)
```

Change `SettingsConsoleShell.tabViews` from one widget to `List<Widget>`;
wrap the selected child in the existing header/content column. Pass the existing
eight settings bodies as that list from `SettingsPage`.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/views/settings_console_shell_test.dart`

Expected: PASS.

- [ ] **Step 5: Format and verify**

Run: `dart format lib/views/settings/settings_console_shell.dart lib/views/settings/settings_sheet.dart test/views/settings_console_shell_test.dart && flutter analyze`

Expected: formatter exits 0; analysis has no findings in modified files.

