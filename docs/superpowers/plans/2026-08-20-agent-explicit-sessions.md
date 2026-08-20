# Agent Explicit Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each new Agent tab owns a new empty session; saved sessions are continued only by explicit selection and can be active in one tab at a time.

**Architecture:** A new file-backed registry stores session descriptors. Process-local leases enforce single-tab ownership while existing `AgentSessionStore` and `AgentOutputStore` keep data per session id. The Agent overlay adds New and Continue actions, while Clear continues to empty only the active session.

**Tech Stack:** Flutter/Dart, `dart:io`, `flutter_test`.

## Global Constraints

- New tabs never derive a session from shell, cwd, or environment.
- Leases are process-local and release on overlay disposal or app restart.
- `/clear` retains the active session id and lease.
- Stop retains the active session lease.
- No automatic history retrieval is introduced.

---

### Task 1: Create the registry and lease service

**Files:**

- Create: `lib/services/agent_session_registry.dart`
- Create: `test/services/agent_session_registry_test.dart`

**Interfaces:** `AgentSessionDescriptor(id, title, createdAt, updatedAt)`, `AgentSessionLease(session, release())`, and `AgentSessionRegistry.createAndAcquire()`, `listAvailable()`, `acquire(id)`, `release(lease)`, `touch(id, title:)`, and `delete(id)`.

- [ ] **Step 1: Write failing tests**

```dart
test('a lease excludes its session until released', () async {
  final first = await registry.createAndAcquire();
  expect((await registry.listAvailable()).map((s) => s.id), isNot(contains(first.session.id)));
  await first.release();
  expect((await registry.listAvailable()).map((s) => s.id), contains(first.session.id));
});
```

Also test distinct ids for repeated new sessions, acquisition rejection for an already leased id, persistence across a fresh registry instance, and deletion rejection for a lease-held id.

- [ ] **Step 2: Verify red**

Run: `flutter test test/services/agent_session_registry_test.dart`

Expected: FAIL because the registry does not exist.

- [ ] **Step 3: Implement minimal registry**

Store schema-versioned descriptors atomically in `agent-sessions/index.json`; allow tests to inject the index file. Generate `session-` plus 24 secure random hex characters. Persist descriptors only; retain lease ids and opaque lease tokens in memory. `acquire` rejects nonexistent or leased ids, and `release` requires the exact token. `delete` rejects leased ids and removes the unlocked descriptor.

- [ ] **Step 4: Verify green**

Run: `flutter test test/services/agent_session_registry_test.dart && dart analyze lib/services/agent_session_registry.dart test/services/agent_session_registry_test.dart`

Expected: PASS; analyzer reports no issues.

### Task 2: Bind overlays to explicit sessions

**Files:**

- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:** `AiAssistantOverlay` accepts an optional registry for tests. The state owns `_activeSession`, creates stores from `lease.session.id`, and releases the lease on disposal.

- [ ] **Step 1: Write failing tests**

Add source/widget coverage that `initState` calls `createAndAcquire()` instead of `AgentSessionStore.idForScope`, disposal releases the active lease, and two overlays sharing one registry receive distinct empty session ids. Assert `_clearChat` retains the active lease.

- [ ] **Step 2: Verify red**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: FAIL because sessions remain scope-derived.

- [ ] **Step 3: Implement ownership lifecycle**

Create/lease a new session asynchronously in `initState`; disable input and session controls until ready. Replace scope-derived construction with stores bound to the leased id. Do not restore any saved transcript for a new session. Dispose saves idle history then releases its lease. Clear continues to call only active stores' `clear()` methods and retains the lease.

- [ ] **Step 4: Verify green**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart && dart analyze lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart`

Expected: PASS; analyzer reports no issues.

### Task 3: Add New, Continue, and Delete session UI

**Files:**

- Modify: `lib/widgets/ai_assistant_panel_widgets.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `test/widgets/agent_panel_layout_invariants_test.dart`

**Interfaces:** `_AgentHeader` receives `sessionTitle`, `onNewSession`, `onContinueSession`, and enabled state. The state implements `_newSession()`, `_showContinueSessionPicker()`, `_continueSession(descriptor)`, and `_deleteSession(descriptor)`.

- [ ] **Step 1: Write failing UI tests**

Assert header `New` and `Continue` affordances, wiring to the state methods, and a guard that prevents switching while `_agentEngaged`. Assert delete exists only in the session picker.

- [ ] **Step 2: Verify red**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart`

Expected: FAIL because actions/picker do not exist.

- [ ] **Step 3: Implement controls**

New persists current idle history, creates/acquires a new lease, then releases the old lease and clears in-memory history. Continue lists only `registry.listAvailable()` sessions ordered by update time; it acquires the target before releasing current, swaps stores, and restores only the selected snapshot. If acquisition fails, leave current unchanged and show a notice. Delete asks confirmation, clears the selected session's snapshot/artifacts, and deletes it only when unlocked. Disable actions while busy or awaiting decisions.

- [ ] **Step 4: Verify green**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart test/widgets/ai_assistant_panel_selection_test.dart`

Expected: PASS.

### Task 4: Import legacy sessions and update titles

**Files:**

- Modify: `lib/services/agent_session_registry.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `test/services/agent_session_registry_test.dart`

**Interfaces:** `initialize()` discovers valid legacy snapshots as unlocked descriptors. The first non-empty prompt calls `touch` with a whitespace-normalized 80-character title.

- [ ] **Step 1: Write failing migration tests**

Test that a valid unregistered snapshot becomes an available legacy session without auto-opening, invalid JSON is skipped, and `touch` updates a capped title/time.

- [ ] **Step 2: Verify red**

Run: `flutter test test/services/agent_session_registry_test.dart`

Expected: FAIL because migration and title updates do not exist.

- [ ] **Step 3: Implement import/update logic**

During initialization, scan direct `agent-sessions/*.json` entries except `index.json`, parse valid snapshots, import descriptors keyed by snapshot session id with file mtime, and persist registry. Never lease imported sessions automatically. Strip runtime host blocks and collapse whitespace before storing an 80-character title after the first user prompt.

- [ ] **Step 4: Final verification and commit**

Run:

```bash
dart format lib/services/agent_session_registry.dart lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/services/agent_session_registry_test.dart test/widgets/ai_assistant_panel_selection_test.dart test/widgets/agent_panel_layout_invariants_test.dart
flutter test
dart analyze lib/services/agent_session_registry.dart lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/services/agent_session_registry_test.dart test/widgets/ai_assistant_panel_selection_test.dart test/widgets/agent_panel_layout_invariants_test.dart
git add lib/services/agent_session_registry.dart lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_widgets.dart test/services/agent_session_registry_test.dart test/widgets/ai_assistant_panel_selection_test.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat(agent): add explicit locked sessions"
```

Expected: full tests pass, targeted analysis reports no issues, and one feature commit is created.
