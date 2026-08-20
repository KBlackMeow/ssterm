# Agent Auto File Write Trust Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Auto mode create new files in the Agent cwd or `/tmp`, and update only files trusted by a successful Auto write or explicit Apply during the current panel lifetime.

**Architecture:** A pure `AgentFileWriteTrust` service owns normalized path-scope checks and the `(path, mtime)` session-only trust ledger. The overlay delegates proposal decisions to it after adapter preview; auto-approved writes use the same atomic adapter commit and LLM feedback as manual Apply, while all other requests retain the existing cards.

**Tech Stack:** Flutter/Dart, `package:path`, existing `FileSystemAdapter`, `flutter_test`.

## Global Constraints

- Auto requires both the existing Auto toggle and `AgentConfig.fileWriteEnabled`.
- Only paths within the adapter's current directory or `/tmp` may be auto-approved.
- Trust is exact-path, mtime-bound, panel-lifetime-only; it must not be persisted in snapshots.
- Every automatic result remains visible in the transcript; existing manual card behavior remains unchanged.

---

### Task 1: Implement the pure file-trust policy

**Files:**
- Create: `lib/services/agent_file_write_trust.dart`
- Create: `test/services/agent_file_write_trust_test.dart`

**Interfaces:**
- Consumes: `FileWritePreview` from `lib/services/file_write_service.dart`.
- Produces: `AgentFileWriteTrust.canAutoCreate`, `canAutoUpdate`, `recordSuccessfulWrite`, and `clear`.

- [ ] **Step 1: Write failing policy tests**

```dart
expect(
  trust.canAutoCreate(
    preview: newPreview('/workspace/demo.txt'),
    currentDirectory: '/workspace',
  ),
  isTrue,
);
expect(
  trust.canAutoCreate(
    preview: existingPreview('/workspace/a'),
    currentDirectory: '/workspace',
  ),
  isFalse,
);
```

Also test `/tmp`, exact-path trust after `recordSuccessfulWrite`, mtime mismatch rejection, and `clear` removing trust.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/agent_file_write_trust_test.dart`  
Expected: FAIL because `AgentFileWriteTrust` does not exist.

- [ ] **Step 3: Write minimal implementation**

```dart
class AgentFileWriteTrust {
  bool canAutoCreate({required FileWritePreview preview, required String? currentDirectory});
  bool canAutoUpdate({required FileWritePreview preview, required String? currentDirectory});
  void recordSuccessfulWrite(FileWriteResult result);
  void clear();
}
```

Normalize POSIX-style paths with `package:path`; accept an exact current-directory descendant or `/tmp` descendant, and store only a non-null result mtime per resolved path.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/services/agent_file_write_trust_test.dart`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/agent_file_write_trust.dart test/services/agent_file_write_trust_test.dart
git commit -m "feat(agent): add session file write trust policy"
```

### Task 2: Apply the policy to write and edit proposals

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart`
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- Consumes: `AgentFileWriteTrust`, `FileSystemAdapter.preview`, and the existing `_autoExecute` flag.
- Produces: automatic commits with visible results and retained manual proposal behavior.

- [ ] **Step 1: Write failing overlay regression tests**

Add focused tests asserting the loop passes `_autoExecute` to both proposal methods, manual Apply records trust, `_clearChat` clears it, and auto results display `AUTO-CREATED` or `AUTO-UPDATED` rather than Apply / Reject.

- [ ] **Step 2: Run focused panel tests to verify they fail**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart test/widgets/agent_panel_layout_invariants_test.dart`  
Expected: FAIL because no trust policy or automatic-result path exists.

- [ ] **Step 3: Add the minimal integration**

```dart
final shouldAutoCreate = autoExecute && trust.canAutoCreate(...);
final shouldAutoUpdate = autoExecute && trust.canAutoUpdate(...);
if (shouldAutoCreate || shouldAutoUpdate) {
  final result = await adapter.commit(path, content, expectedMtime: preview.mtime);
  trust.recordSuccessfulWrite(result);
  _conversationHistory.add({'role': 'user', 'content': successEnvelope});
  _messages.add(_ChatMessage.autoFileWrite(...));
  return _WriteProposalOutcome.injectedAndContinue;
}
```

Apply the same commit-and-record path to `edit_file`; record successful manual Apply for both write and edit. Clear the ledger in `_clearChat`; do not include it in session snapshot data.

- [ ] **Step 4: Run focused tests to verify they pass**

Run: `flutter test test/services/agent_file_write_trust_test.dart test/widgets/ai_assistant_panel_selection_test.dart test/widgets/agent_panel_layout_invariants_test.dart`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_tooling.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat(agent): auto-apply trusted file writes"
```

### Task 3: Verify the completed behavior

**Files:**
- Modify: `docs/superpowers/specs/2026-08-20-agent-auto-file-write-trust-boundary-design.md`

- [ ] **Step 1: Mark the specification implemented**

Change the design document status from `待设计确认` to `已实施` only after all verification passes.

- [ ] **Step 2: Run formatter and complete suite**

Run: `dart format lib/services/agent_file_write_trust.dart lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_tooling.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_loop.dart test/services/agent_file_write_trust_test.dart test/widgets/ai_assistant_panel_selection_test.dart && flutter test`  
Expected: formatter makes no unexpected edits and all tests pass.

- [ ] **Step 3: Commit verification/documentation changes**

```bash
git add docs/superpowers/specs/2026-08-20-agent-auto-file-write-trust-boundary-design.md
git commit -m "docs(agent): record auto file write trust policy"
```

## Self-Review

- Spec coverage: Tasks 1–2 cover location, first create, prior approval, mtime conflict and UI/audit behavior; Task 2 clears trust and Task 3 checks it is not persisted.
- Placeholder scan: no TBD/TODO or unspecified tests remain.
- Type consistency: all integration call sites use `AgentFileWriteTrust` and `FileWriteResult` from Task 1.

