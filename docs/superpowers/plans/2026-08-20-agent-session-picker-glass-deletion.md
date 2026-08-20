# Agent Session Picker Glass Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present available Agent sessions in a new-tab-style glass picker and let users immediately delete an inactive session.

**Architecture:** Ownership stays in `AgentSessionRegistry`; `listAvailable()` is the UI filter and `delete()` remains the final lease check. A private glass picker manages only its transient displayed list and returns a selected session to the overlay.

**Tech Stack:** Flutter/Dart, Material, `FrostedGlassSurface`, `flutter_test`.

## Global Constraints

- Render only sessions returned by `AgentSessionRegistry.listAvailable()`.
- Every rendered card has immediate deletion, with no confirmation dialog.
- A leased session cannot be deleted, including during a picker race.
- Failed deletion must not replace the active session or select a card.
- Do not use multi-agent development.

---

### Task 1: Add regression coverage for glass picker deletion

**Files:**

- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`
- Modify: `test/services/agent_session_registry_test.dart`

**Interfaces:** Uses `AgentSessionRegistry.delete(String id)` and `AgentSessionUnavailableException`; produces coverage for released and leased session deletion.

- [ ] **Step 1: Write failing tests**

```dart
test('deletes a released session from the available list', () async {
  final lease = await registry.createAndAcquire();
  await lease.release();
  await registry.delete(lease.session.id);
  expect(
    (await registry.listAvailable()).map((session) => session.id),
    isNot(contains(lease.session.id)),
  );
});

test('continue-session picker uses glass cards with safe deletion', () {
  final source = File('lib/widgets/ai_assistant_panel.dart').readAsStringSync();
  expect(source, contains('class _SessionPicker'));
  expect(source, contains('FrostedGlassSurface('));
  expect(source, contains('_sessionRegistry.delete(session.id)'));
  expect(source, contains("tooltip: 'Delete session'"));
});
```

- [ ] **Step 2: Verify red**

Run `flutter test test/widgets/ai_assistant_panel_selection_test.dart test/services/agent_session_registry_test.dart`.

Expected: the new picker test fails because the current UI uses `AlertDialog` and `ListTile`.

- [ ] **Step 3: Preserve the registry guard**

Keep `AgentSessionRegistry.delete` unchanged: it throws `AgentSessionUnavailableException` before writing whenever `_leasesFor(index).containsKey(id)` is true.

### Task 2: Implement a glass-card picker and immediate delete

**Files:**

- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:** `_SessionPicker(List<AgentSessionDescriptor>, onDelete)` renders cards and returns `AgentSessionDescriptor` using `Navigator.pop`; `_continueSession()` continues only the returned descriptor.

- [ ] **Step 1: Implement the smallest picker to pass tests**

Replace the `AlertDialog` builder in `_continueSession()` with a transparent `Dialog` containing `_SessionPicker`. `_SessionPicker` owns a mutable copy of available descriptors, renders the surface and cards with `FrostedGlassSurface`, and removes a card only after `onDelete(session)` completes. A card tap closes with the descriptor; the delete icon is a separate gesture target and has the exact tooltip `Delete session`.

```dart
Future<void> _deleteAvailableSession(AgentSessionDescriptor session) async {
  try {
    await _sessionRegistry.delete(session.id);
  } on AgentSessionUnavailableException {
    if (!mounted) return;
    setState(() {
      _messages.add(
        _ChatMessage.notice('That session was opened in another Agent tab.'),
      );
    });
    rethrow;
  }
}
```

- [ ] **Step 2: Verify green**

Run `flutter test test/widgets/ai_assistant_panel_selection_test.dart test/services/agent_session_registry_test.dart`.

Expected: all targeted tests pass, including the existing leased-deletion rejection test.

- [ ] **Step 3: Format and analyse**

Run `dart format lib/widgets/ai_assistant_panel.dart test/widgets/ai_assistant_panel_selection_test.dart test/services/agent_session_registry_test.dart && dart analyze lib/widgets/ai_assistant_panel.dart test/widgets/ai_assistant_panel_selection_test.dart test/services/agent_session_registry_test.dart`.

Expected: no formatter or analyzer findings.

### Task 3: Verify integration and commit

**Files:**

- Verify: `lib/widgets/ai_assistant_panel.dart`
- Verify: `lib/services/agent_session_registry.dart`
- Verify: `test/widgets/ai_assistant_panel_selection_test.dart`
- Verify: `test/services/agent_session_registry_test.dart`

**Interfaces:** Verifies the completed Tasks 1–2.

- [ ] **Step 1: Run the full suite**

Run `flutter test`.

Expected: all tests pass.

- [ ] **Step 2: Inspect diff hygiene**

Run `git diff --check && git diff -- lib/widgets/ai_assistant_panel.dart test/widgets/ai_assistant_panel_selection_test.dart test/services/agent_session_registry_test.dart`.

Expected: no whitespace errors and only intended behavior changes.

- [ ] **Step 3: Commit focused changes**

Run `git add lib/widgets/ai_assistant_panel.dart test/widgets/ai_assistant_panel_selection_test.dart test/services/agent_session_registry_test.dart docs/superpowers/plans/2026-08-20-agent-session-picker-glass-deletion.md && git commit -m "feat(agent): add glass session picker deletion"`.

Expected: one focused commit; pre-existing untracked documents remain untouched.
