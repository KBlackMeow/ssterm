# SFTP File Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user open a remote file from ssterm's SFTP browser panel (double-click, or a new "Edit" context-menu item) into a new plain-text editor tab, edit it, and save it back over SFTP — with unsaved-changes-on-close confirmation and mtime-conflict handling.

**Architecture:** A new `AppTabKind.editor` tab kind carries just enough metadata (path, borrowed `SftpClient`, mtime token, a `dirty` `ValueNotifier`, and a `GlobalKey` into the editor widget's state) for the rest of the app to treat it like any other tab. All actual editing state (the `TextEditingController`, the loaded content) lives inside the new `FileEditorView` widget itself. I/O goes through the existing `SftpFileSystemAdapter` (`readContent`/`preview`/`commit`) — no new read/write code, no AI Agent involvement anywhere in this feature.

**Tech Stack:** Flutter/Dart 3, `flutter_test` for the one file with real unit-testable logic (`tab_model.dart`). No new package dependencies.

**Reference spec:** [docs/superpowers/specs/2026-07-20-sftp-file-editor-design.md](../specs/2026-07-20-sftp-file-editor-design.md)

## Global Constraints

- No new pub dependencies.
- Desktop only — `lib/app/main_mobile.dart`/`main_mobile_connections.dart` are NOT touched; mobile's SFTP panel keeps its current behavior unchanged.
- SFTP-only — no local-file editing entry point.
- File-size gate: 4 MB (`4 * 1024 * 1024`), same threshold `FileSystemAdapter.readContent` already enforces — this feature reads that same guard's exception (`FileWriteErrorKind.tooLarge`) rather than re-implementing a size check.
- No new Settings toggle for this feature.
- Error text shown to the user is human-readable prose written for this feature — never reuse `FileWriteService.formatErrorForLlm` (that formatter's wording is instructional to an LLM, e.g. "Do NOT retry", and is wrong for a human-facing UI).
- No new automated test infrastructure for widgets/UI wiring — this project has zero tests for chat-card widgets, tab-bar wiring, or `SftpView`'s interactive behavior (confirmed: `test/sftp_view_test.dart` only covers pure top-level functions like `sftpJoin`/`sftpEntryNameError`, not `SftpViewState` methods). `lib/models/tab_model.dart` is the one file in this plan with an existing, real unit-test file (`test/models/tab_model_test.dart`) and gets real tests. Everything else is verified via `flutter analyze` + full `flutter test` regression + a manual QA checklist.

---

### Task 1: Tab model additions

**Files:**
- Modify: `lib/models/tab_model.dart`
- Test: `test/models/tab_model_test.dart`

**Interfaces:**
- Consumes: `FileEditorViewState` (from `lib/views/file_editor_view.dart`, created in Task 2) — only as a type parameter for `GlobalKey<FileEditorViewState>`, no method calls on it from this file.
- Produces: `AppTabKind.editor`; `AppTab.editorPath`/`editorSftp`/`editorLabel`/`editorMtime`/`editorInitialContent`/`editorDirty`/`editorViewKey` fields; `AppTab.editor({required String path, required SftpClient sftp, required String label, required DateTime? mtime, required String initialContent})` factory; `AppTab.icon` handles `AppTabKind.editor`.

This task is written to land BEFORE Task 2 exists (`file_editor_view.dart` doesn't exist yet when this task starts) — Step 3 below creates a minimal placeholder file first so the import resolves, then Task 2 replaces it with the real widget. This keeps Task 1 buildable and testable in isolation without needing to guess Task 2's full implementation.

- [ ] **Step 1: Write the failing tests**

Add to `test/models/tab_model_test.dart`, right after the existing `group('AppTab.icon', ...)` block (currently ending at line 162, just before the closing `}` of `main()`):

```dart
  group('AppTab.editor', () {
    test('factory sets kind, path, sftp, label, mtime, and initial content', () {
      final mtime = DateTime.utc(2026, 1, 1);
      final tab = AppTab.editor(
        path: '/etc/hosts',
        sftp: FakeSftpClient(),
        label: 'ssh: prod-db',
        mtime: mtime,
        initialContent: 'localhost 127.0.0.1',
      );
      expect(tab.kind, equals(AppTabKind.editor));
      expect(tab.editorPath, equals('/etc/hosts'));
      expect(tab.editorSftp, isNotNull);
      expect(tab.editorLabel, equals('ssh: prod-db'));
      expect(tab.editorMtime, equals(mtime));
      expect(tab.editorInitialContent, equals('localhost 127.0.0.1'));
      expect(tab.title, equals('/etc/hosts'));
    });

    test('starts not dirty', () {
      final tab = AppTab.editor(
        path: '/tmp/x',
        sftp: FakeSftpClient(),
        label: 'ssh: x',
        mtime: null,
        initialContent: '',
      );
      expect(tab.editorDirty.value, isFalse);
    });

    test('editorViewKey is a fresh GlobalKey per tab', () {
      final a = AppTab.editor(
          path: '/a', sftp: FakeSftpClient(), label: 'x', mtime: null, initialContent: '');
      final b = AppTab.editor(
          path: '/b', sftp: FakeSftpClient(), label: 'x', mtime: null, initialContent: '');
      expect(identical(a.editorViewKey, b.editorViewKey), isFalse);
    });
  });

  group('AppTab.icon', () {
    test('editor tab has edit icon', () {
      final tab = AppTab.editor(
          path: '/a', sftp: FakeSftpClient(), label: 'x', mtime: null, initialContent: '');
      expect(tab.icon, equals(Icons.edit_note));
    });
  });
```

This test file needs a `FakeSftpClient` — check whether `test/models/tab_model_test.dart` already has one (it likely doesn't need a real `SSHClient`/`SftpClient` today since existing tests use `AppTab.local`/`AppTab.ssh`, neither of which requires a live `SftpClient` at construction time). Add this minimal fake near the top of the test file, right after the imports:

```dart
/// Minimal no-op stand-in — `AppTab.editor` only stores the reference,
/// it never calls any method on it, so a real [SftpClient] (which
/// requires a live SSH transport to construct) isn't needed here.
class FakeSftpClient implements SftpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
```

Confirm `import 'package:dartssh2/dartssh2.dart';` and `import 'package:flutter/material.dart';` (for `Icons`) are present at the top of `test/models/tab_model_test.dart` — add them if missing.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/models/tab_model_test.dart`
Expected: FAIL — `The method 'editor' isn't defined for the type 'AppTab'` (and similarly for the new fields/`AppTabKind.editor`).

- [ ] **Step 3: Create a placeholder `FileEditorViewState` so the import resolves**

Create `lib/views/file_editor_view.dart` with just enough to compile — Task 2 replaces this entire file with the real widget:

```dart
import 'package:flutter/material.dart';

/// Placeholder — replaced in full by Task 2 of the SFTP file editor plan.
/// Exists here only so `tab_model.dart` can reference
/// `GlobalKey<FileEditorViewState>` before the real widget is built.
class FileEditorView extends StatefulWidget {
  const FileEditorView({super.key});

  @override
  State<FileEditorView> createState() => FileEditorViewState();
}

class FileEditorViewState extends State<FileEditorView> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
```

- [ ] **Step 4: Implement the `tab_model.dart` changes**

Add the import at the top of `lib/models/tab_model.dart` (after the existing `import 'transfer_task.dart';` on line 12):

```dart
import 'transfer_task.dart';
import '../views/file_editor_view.dart';
```

Change the enum (currently line 14):

```dart
enum AppTabKind { local, ssh, sshConnecting, sshError, settings, editor }
```

Add fields to `AppTab` — insert right after `TransferManager? transferManager;` (currently line 63, still inside the "Pane 0" section, before the `terminalLocked` doc comment):

```dart
  TransferManager? transferManager;

  // ── Editor-tab-only state (AppTabKind.editor) ────────────────────────────
  // Populated only when `kind == AppTabKind.editor`. Kept as a separate,
  // clearly-labelled group rather than mixed into the pane-0 fields above
  // because an editor tab has no terminal/PTY/split state at all — it's a
  // lightweight tab like `settings`, not a terminal session.

  /// Remote absolute path this tab is editing.
  String? editorPath;

  /// SFTP client BORROWED from the source SSH tab at open time — this tab
  /// does not own it and must never close it. If the source SSH tab
  /// reconnects (getting a new client) or disconnects (closing this one),
  /// this reference goes stale; `FileEditorView` surfaces that as an
  /// ordinary save error rather than trying to follow the reconnect.
  SftpClient? editorSftp;

  /// Display label for the source SSH tab, e.g. "ssh: prod-db" — shown in
  /// error messages so the user knows which connection is involved.
  String? editorLabel;

  /// mtime captured at open time (or the most recent successful
  /// save/reload) — passed to `FileSystemAdapter.commit` as the
  /// concurrency token.
  DateTime? editorMtime;

  /// Content read by the SFTP panel at open time. Consumed EXACTLY ONCE
  /// by `FileEditorView.initState` (via `_buildPrimaryContent`'s
  /// construction in `main_views.dart`, Task 4) to seed its
  /// `TextEditingController` — `_buildPrimaryContent` runs on every
  /// rebuild, but `initState` only runs once per widget lifetime, so
  /// after the first build this field is stale/unused and the
  /// widget's own controller is the sole source of truth.
  String? editorInitialContent;

  /// True while the editor's buffer differs from the last-saved/loaded
  /// content. Written by `FileEditorView`, read by the tab-close
  /// confirmation gate — kept on `AppTab` (not buried inside the widget's
  /// State) so the close handler can check it even before/without
  /// querying the widget itself.
  final ValueNotifier<bool> editorDirty = ValueNotifier(false);

  /// Reach-into-the-widget handle, same pattern as [terminalViewKey]
  /// below — lets the tab-close confirmation flow (which runs outside
  /// `FileEditorView`'s own widget tree) call `.save()` on the live
  /// editor state when the user chooses "Save" from the close dialog.
  final editorViewKey = GlobalKey<FileEditorViewState>();
```

Add the factory — insert right after `factory AppTab.ssh(...)` (currently lines 116-117):

```dart
  /// Convenience factory used in tests and when the user opens a remote
  /// file from the SFTP panel. [title] is the path itself — editor tabs
  /// don't have a separate short display name, the full path IS the
  /// identity of the tab.
  factory AppTab.editor({
    required String path,
    required SftpClient sftp,
    required String label,
    required DateTime? mtime,
    required String initialContent,
  }) => AppTab._(kind: AppTabKind.editor, title: path)
    ..editorPath = path
    ..editorSftp = sftp
    ..editorLabel = label
    ..editorMtime = mtime
    ..editorInitialContent = initialContent;
```

Add the `dispose()` note and `icon` branch. First, add a one-line comment to `dispose()` (currently lines 231-255) — insert right after `void dispose() {` (line 231):

```dart
  void dispose() {
    // NOTE: editorDirty/editorViewKey need no explicit cleanup here —
    // ValueNotifier.dispose() is skipped deliberately (see below); the
    // GlobalKey has no disposable resource of its own. editorSftp is a
    // BORROWED reference (see its doc comment above) and must NOT be
    // closed here — that would tear down the source SSH tab's live
    // connection out from under it.
    manuallyDisconnected = true;
```

Then add `editorDirty.dispose();` near the other `.dispose()` calls at the end of the method (currently right before the closing brace, after `terminalLocked.dispose();` on line 254):

```dart
    terminalController.dispose();
    splitTerminalController.dispose();
    transferManager?.dispose();
    terminalLocked.dispose();
    editorDirty.dispose();
  }
```

Finally, update the `icon` getter (currently lines 257-263):

```dart
  IconData get icon => switch (kind) {
    AppTabKind.local => Icons.terminal,
    AppTabKind.ssh => Icons.lock_outline,
    AppTabKind.sshConnecting => Icons.lock_outline,
    AppTabKind.sshError => Icons.error_outline,
    AppTabKind.settings => Icons.settings_outlined,
    AppTabKind.editor => Icons.edit_note,
  };
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/models/tab_model_test.dart`
Expected: PASS — all tests green, including the 5 new ones.

- [ ] **Step 6: Run the full test suite to confirm nothing else broke**

Run: `flutter test`
Expected: same baseline as before this task (416 passed / 1 skipped / 1 pre-existing unrelated failure in `test/services/local_pty_env_test.dart` — Windows-only test polluted by macOS host PATH, already known, not this feature's concern) — no NEW failures. `AppTabKind` gaining a new enum value is a `switch`-exhaustiveness change: if `flutter test` reveals a compile error in some OTHER file with an exhaustive `switch (tab.kind)`/`switch (someAppTabKind)`, that confirms a real call site needs a case added — note it and continue; Tasks 3-4 below already account for the two switches this plan knows about (`_buildPrimaryContent` in `main_views.dart`, and `_activeTabCanSplit`'s `||`-chain doesn't need a case since it's not exhaustive-checked). If `flutter test` surfaces an exhaustiveness error in a file NOT mentioned anywhere in this plan, STOP and report it — don't guess a fix, escalate as NEEDS_CONTEXT so the plan can be corrected.

- [ ] **Step 7: Commit**

```bash
git add lib/models/tab_model.dart lib/views/file_editor_view.dart test/models/tab_model_test.dart
git commit -m "$(cat <<'EOF'
Add AppTabKind.editor and AppTab editor-tab fields

New lightweight tab kind (path/borrowed-sftp/label/mtime/dirty-flag +
a GlobalKey into the editor widget's state, mirroring the existing
terminalViewKey pattern) for the upcoming SFTP-panel file editor.
Ships with a placeholder FileEditorView so this compiles standalone;
the real widget lands in the next commit.
EOF
)"
```

---

### Task 2: `FileEditorView` widget

**Files:**
- Modify: `lib/views/file_editor_view.dart` (replaces the Task 1 placeholder entirely)

**Interfaces:**
- Consumes: `SftpFileSystemAdapter`/`FileWriteException`/`FileWriteErrorKind`/`FileWriteResult`/`FileWritePreview` from `lib/services/file_write_service.dart` (`readContent(path) → Future<String>`, `preview(path) → Future<FileWritePreview>`, `commit(path, content, {expectedMtime}) → Future<FileWriteResult>`); `AppColors`/`PopupSurface` from `lib/widgets/frosted_glass.dart`.
- Produces: `FileEditorView({required String path, required SftpClient sftp, required String label, required String initialContent, required DateTime? initialMtime, required ValueNotifier<bool> dirty})`; `FileEditorViewState.save() → Future<bool>` (public — Task 4's close-confirmation flow calls this through `AppTab.editorViewKey`).

- [ ] **Step 1: Replace the placeholder with the full widget**

Replace the entire contents of `lib/views/file_editor_view.dart`:

```dart
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_write_service.dart';
import '../widgets/frosted_glass.dart';

const _kBg = Color(0xFF1E1E1E);
const _kToolbar = Color(0x66252525);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgDim = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);
const _kDanger = Color(0xFFFF6E67);

/// Plain-text editor tab for a remote file opened from the SFTP panel.
/// I/O goes entirely through [SftpFileSystemAdapter] — no AI Agent
/// involvement, no LLM-facing envelopes; every error string here is
/// written for a human reading the toolbar.
class FileEditorView extends StatefulWidget {
  const FileEditorView({
    super.key,
    required this.path,
    required this.sftp,
    required this.label,
    required this.initialContent,
    required this.initialMtime,
    required this.dirty,
  });

  /// Remote absolute path being edited.
  final String path;

  /// SFTP client borrowed from the source SSH tab — see
  /// `AppTab.editorSftp`'s doc comment for the ownership/staleness
  /// contract this widget relies on.
  final SftpClient sftp;

  /// Display label for the source connection, used in error text.
  final String label;

  /// Content loaded by the SFTP panel BEFORE this tab was created —
  /// used once, in [State.initState], to seed the [TextEditingController].
  final String initialContent;

  /// mtime captured alongside [initialContent] — the initial concurrency
  /// token for [FileEditorViewState.save].
  final DateTime? initialMtime;

  /// Mirror of the buffer's dirty state, owned by the host `AppTab` (see
  /// `AppTab.editorDirty`) so the tab-close confirmation gate can read it
  /// without needing this widget mounted.
  final ValueNotifier<bool> dirty;

  @override
  State<FileEditorView> createState() => FileEditorViewState();
}

enum _ConflictChoice { overwrite, reload }

class FileEditorViewState extends State<FileEditorView> {
  late final TextEditingController _controller;
  late String _originalContent;
  DateTime? _mtime;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
    _originalContent = widget.initialContent;
    _mtime = widget.initialMtime;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final isDirty = _controller.text != _originalContent;
    if (widget.dirty.value != isDirty) widget.dirty.value = isDirty;
  }

  SftpFileSystemAdapter get _adapter =>
      SftpFileSystemAdapter(sftp: widget.sftp, label: widget.label);

  /// Saves the current buffer. Returns `true` when it's safe for the
  /// caller to close this tab afterward (save succeeded, OR the user
  /// resolved an mtime conflict by choosing to reload and discard local
  /// changes) — `false` when the tab should stay open (save failed, or
  /// the conflict dialog didn't resolve to either outcome).
  Future<bool> save() async {
    if (_saving) return false;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await _adapter.commit(
        widget.path,
        _controller.text,
        expectedMtime: _mtime,
      );
      if (!mounted) return true;
      setState(() {
        _originalContent = _controller.text;
        _mtime = result.mtime;
        _saving = false;
      });
      widget.dirty.value = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return true;
    } on FileWriteException catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      if (e.kind == FileWriteErrorKind.mtimeMismatch) {
        return _resolveConflict();
      }
      setState(() => _error = _humanSaveError(e));
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _error = 'Save failed: $e';
      });
      return false;
    }
  }

  Future<bool> _resolveConflict() async {
    final colors = AppColors.maybeOf(context);
    final choice = await showDialog<_ConflictChoice>(
      context: context,
      builder: (ctx) => Theme(
        data: Theme.of(context)
            .copyWith(extensions: colors != null ? {colors} : null),
        child: const _ConflictDialog(),
      ),
    );
    if (!mounted) return false;
    if (choice == _ConflictChoice.overwrite) {
      try {
        final result = await _adapter.commit(widget.path, _controller.text);
        if (!mounted) return true;
        setState(() {
          _originalContent = _controller.text;
          _mtime = result.mtime;
        });
        widget.dirty.value = false;
        return true;
      } catch (e) {
        if (!mounted) return false;
        setState(() => _error = 'Save failed: $e');
        return false;
      }
    }
    if (choice == _ConflictChoice.reload) {
      await _reload();
      return true;
    }
    return false;
  }

  Future<void> _reload() async {
    try {
      final content = await _adapter.readContent(widget.path);
      final preview = await _adapter.preview(widget.path);
      if (!mounted) return;
      setState(() {
        _controller.text = content;
        _originalContent = content;
        _mtime = preview.mtime;
        _error = null;
      });
      widget.dirty.value = false;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Reload failed: $e');
    }
  }

  String _humanSaveError(FileWriteException e) => switch (e.kind) {
    FileWriteErrorKind.permission => 'Permission denied writing to this file.',
    FileWriteErrorKind.notSupported =>
      'The connection to this file is no longer available.',
    FileWriteErrorKind.tooLarge =>
      'File is too large to save from the editor.',
    FileWriteErrorKind.parentMissing =>
      'The containing folder no longer exists.',
    FileWriteErrorKind.invalidPath => 'Invalid path.',
    FileWriteErrorKind.io => 'Save failed: ${e.message}',
    FileWriteErrorKind.mtimeMismatch =>
      'Save failed: ${e.message}', // unreachable — handled by _resolveConflict above
  };

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final fg = colors?.foreground ?? _kFgActive;
    final fgDim = colors?.foregroundDim ?? _kFgDim;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
          save();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          save();
        },
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: _kBg,
          child: Column(
            children: [
              _buildToolbar(fg, fgDim),
              if (_error != null) _buildErrorBar(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(
                      color: fg,
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13,
                      height: 1.4,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isCollapsed: true,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(Color fg, Color fgDim) {
    return Container(
      height: 40,
      color: _kToolbar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(Icons.edit_note, size: 16, color: fgDim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.path,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: widget.dirty,
            builder: (_, dirty, __) => Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: dirty ? _kAccent : Colors.transparent,
                shape: BoxShape.circle,
              ),
            ),
          ),
          TextButton(
            onPressed: _reload,
            child: Text('Reload', style: TextStyle(color: fgDim, fontSize: 12)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: _saving ? null : () => save(),
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save',
                    style: TextStyle(color: _kAccent, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBar() {
    return Container(
      width: double.infinity,
      color: _kDanger.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(_error!, style: const TextStyle(color: _kDanger, fontSize: 12)),
    );
  }
}

class _ConflictDialog extends StatelessWidget {
  const _ConflictDialog();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final fill = colors?.popup ?? FrostedGlassStyle.menuFillFrosted;
    final fg = colors?.foreground ?? _kFgActive;
    final fgDim = colors?.foregroundDim ?? _kFgDim;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 380,
        child: PopupSurface(
          color: fill,
          backdropBlur: 20,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'File changed',
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'This file was modified elsewhere while you were editing it.',
                  style: TextStyle(color: fgDim, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, _ConflictChoice.reload),
                      child: Text(
                        'Reload (discard my changes)',
                        style: TextStyle(color: fgDim),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, _ConflictChoice.overwrite),
                      child: const Text(
                        'Overwrite',
                        style: TextStyle(color: _kDanger),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run static analysis**

Run: `flutter analyze lib/views/file_editor_view.dart`
Expected: `No issues found!`

- [ ] **Step 3: Run the full test suite (regression check)**

Run: `flutter test`
Expected: same as Task 1's baseline — no new failures. This task adds no new tests of its own (see Global Constraints — no automated test infra for widgets in this project), so this run is purely a compile/regression check.

- [ ] **Step 4: Commit**

```bash
git add lib/views/file_editor_view.dart
git commit -m "$(cat <<'EOF'
Implement FileEditorView

Plain-text editor for a remote file: dirty tracking via a
TextEditingController vs a snapshot, Cmd/Ctrl+S save, an mtime-conflict
dialog (overwrite vs. reload-and-discard), and human-readable error
text distinct from the AI Agent's LLM-facing envelopes. Not yet wired
into any tab — that's Tasks 3-4.
EOF
)"
```

---

### Task 3: Wire the open-editor trigger in the SFTP panel

**Files:**
- Modify: `lib/views/sftp_view.dart`
- Modify: `lib/views/sftp_view_menus.dart`

**Interfaces:**
- Consumes: `SftpFileSystemAdapter` (`preview`/`readContent`) from `lib/services/file_write_service.dart` — already imported transitively? No: `sftp_view.dart` does NOT currently import `file_write_service.dart` — add it.
- Produces: `SftpView.onOpenEditorTab` constructor parameter, type `void Function({required String path, required String initialContent, required DateTime? mtime})?`; `SftpViewState._openInEditor(SftpName entry) → Future<void>` (declared abstract on `_SftpMenusMixin` so the context menu can call it, exactly like `_download`/`_rename`/`_delete` already are).

- [ ] **Step 1: Add the `onOpenEditorTab` callback to the `SftpView` widget**

In `lib/views/sftp_view.dart`, add the import (after `import '../widgets/frosted_glass.dart';` on line 12):

```dart
import '../widgets/frosted_glass.dart';
import '../services/file_write_service.dart';
```

Add the constructor parameter and field — modify the constructor (currently lines 85-96) and the field list (lines 98-113):

```dart
class SftpView extends StatefulWidget {
  const SftpView({
    super.key,
    required this.sftp,
    required this.host,
    required this.transferManager,
    this.remotePath,
    this.panelPosition,
    this.onPanelPositionChanged,
    this.onClose,
    this.onOpenEditorTab,
    this.showToolbar = true,
    this.chromeBackground = const Color(0xFF1E1E2A),
  });

  final SftpClient sftp;
  final String host;
  final TransferManager transferManager;

  /// When set, the panel follows this path (e.g. synced from the SSH shell cwd).
  final ValueNotifier<String>? remotePath;

  final SftpPanelPosition? panelPosition;
  final ValueChanged<SftpPanelPosition>? onPanelPositionChanged;
  final VoidCallback? onClose;

  /// Called after the user opens a file in the editor (double-click, or
  /// the "Edit" context-menu item) AND its content has already been
  /// successfully read. The host is responsible for turning this into a
  /// new `AppTabKind.editor` tab — this widget knows nothing about tabs.
  /// Null on hosts that don't support opening an editor tab (there are
  /// none today, but the callback stays optional for symmetry with
  /// [onClose]/[onPanelPositionChanged]).
  final void Function({
    required String path,
    required String initialContent,
    required DateTime? mtime,
  })? onOpenEditorTab;

  /// Set to false to hide the compact toolbar (use in full-screen page mode).
  final bool showToolbar;

  /// Solid background for action sheets / non-frosted panels.
  final Color chromeBackground;

  @override
  State<SftpView> createState() => SftpViewState();
}
```

- [ ] **Step 2: Implement `_openInEditor`**

In `lib/views/sftp_view.dart`, add the method to `SftpViewState` — insert right after `_navigateEntry` (currently ending at line 434, before `_tapMobileSymlink`):

```dart
  /// Opens [entry] in a new editor tab. No-ops on directories and on
  /// symlinks that resolve to a directory (same resolution check
  /// `_navigateEntry` already does). Validates size (4 MB cap, same
  /// threshold `FileSystemAdapter.readContent` enforces) and reads the
  /// content BEFORE calling `widget.onOpenEditorTab` — a failure here
  /// shows a [SnackBar] and never creates a tab, matching the design's
  /// "a doomed open never reaches the UI" rule (same shape as the AI
  /// agent's edit_file match-validation-before-card rule).
  Future<void> _openInEditor(SftpName entry) async {
    if (entry.attr.isDirectory) return;
    if (entry.attr.isSymbolicLink) {
      try {
        final targetPath = sftpJoin(_path, entry.filename);
        final stat = await widget.sftp.stat(targetPath);
        if (stat.isDirectory) return;
      } catch (_) {}
    }
    final onOpen = widget.onOpenEditorTab;
    if (onOpen == null) return;

    final path = sftpJoin(_path, entry.filename);
    final adapter = SftpFileSystemAdapter(sftp: widget.sftp, label: widget.host);
    try {
      final preview = await adapter.preview(path);
      if (preview.existingSize > 4 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File is too large to edit (over 4 MB).'),
            ),
          );
        }
        return;
      }
      final content = await adapter.readContent(path);
      onOpen(path: path, initialContent: content, mtime: preview.mtime);
    } on FileWriteException catch (e) {
      if (!mounted) return;
      final message = e.kind == FileWriteErrorKind.io
          ? 'Not a text file — cannot edit.'
          : 'Could not open file: ${e.message}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open file: $e')));
    }
  }
```

- [ ] **Step 3: Wire the double-click on the desktop file row**

In `lib/views/sftp_view.dart`, modify the row's `InkWell` (currently lines 870-871):

```dart
          child: InkWell(
            onTap: () => _navigateEntry(e),
            onDoubleTap: () => _openInEditor(e),
```

- [ ] **Step 4: Add the "Edit" context-menu item**

In `lib/views/sftp_view_menus.dart`, add `Future<void> _openInEditor(SftpName entry);` to the mixin's abstract declarations (currently lines 10-15, right after `Future<void> _download(SftpName entry);`):

```dart
mixin _SftpMenusMixin on State<SftpView> {
  /// Implemented by [SftpViewState]; the mixin only consumes them.
  String get _path;
  Future<void> _listDir(String path);
  Future<void> _download(SftpName entry);
  Future<void> _openInEditor(SftpName entry);
  Future<void> _rename(SftpName entry);
  Future<void> _delete(SftpName entry);
```

Add the menu item — modify `_showDesktopContextMenu` (currently lines 87-140): insert an "Edit" entry right after the existing `if (!isDir)` Download block (currently lines 100-111), and a matching `case` in the `switch`:

```dart
    final action = await showFrostedMenu<String>(
      context: context,
      position: position,
      items: [
        if (!isDir)
          PopupMenuItem(
            value: 'download',
            height: 36,
            child: Builder(
              builder: (ctx) => Text('Download',
                  style: TextStyle(
                    color: AppColors.maybeOf(ctx)?.foreground ?? const Color(0xFFC7C7C7),
                    fontSize: 13,
                  )),
            ),
          ),
        if (!isDir)
          PopupMenuItem(
            value: 'edit',
            height: 36,
            child: Builder(
              builder: (ctx) => Text('Edit',
                  style: TextStyle(
                    color: AppColors.maybeOf(ctx)?.foreground ?? const Color(0xFFC7C7C7),
                    fontSize: 13,
                  )),
            ),
          ),
        PopupMenuItem(
          value: 'rename',
          height: 36,
          child: Builder(
            builder: (ctx) => Text('Rename',
                style: TextStyle(
                  color: AppColors.maybeOf(ctx)?.foreground ?? const Color(0xFFC7C7C7),
                  fontSize: 13,
                )),
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Text('Delete',
              style: TextStyle(color: Color(0xFFFF6E67), fontSize: 13)),
        ),
      ],
    );

    switch (action) {
      case 'download':
        await _download(e);
      case 'edit':
        await _openInEditor(e);
      case 'rename':
        await _rename(e);
      case 'delete':
        await _delete(e);
    }
```

- [ ] **Step 5: Run static analysis**

Run: `flutter analyze lib/views/sftp_view.dart lib/views/sftp_view_menus.dart`
Expected: `No issues found!`

- [ ] **Step 6: Run the full test suite (regression check)**

Run: `flutter test`
Expected: same baseline as before — `test/sftp_view_test.dart` only covers pure top-level functions untouched by this task, so it should be unaffected; no new failures anywhere.

- [ ] **Step 7: Commit**

```bash
git add lib/views/sftp_view.dart lib/views/sftp_view_menus.dart
git commit -m "$(cat <<'EOF'
Wire double-click and an Edit menu item to open the file editor

SftpView gains an onOpenEditorTab callback and _openInEditor, which
validates size (4MB cap) and reads content BEFORE invoking the
callback, so a doomed open never reaches the tab layer. Not yet
connected to a host that creates tabs — that's Task 4.
EOF
)"
```

---

### Task 4: Thread the callback through and wire tab creation + close confirmation

**Files:**
- Modify: `lib/views/ssh_session_view.dart`
- Modify: `lib/app/main_views.dart`
- Modify: `lib/app/main_ssh.dart`

**Interfaces:**
- Consumes: `SftpView.onOpenEditorTab` (Task 3); `AppTab.editor(...)`/`editorPath`/`editorSftp`/`editorLabel`/`editorMtime`/`editorDirty`/`editorViewKey` (Task 1); `FileEditorView`/`FileEditorViewState.save()` (Task 2).
- Produces: `_TerminalHomeSshMethods._openEditorTab({required _Tab sourceTab, required String path, required String initialContent, required DateTime? mtime})`; `_TerminalHomeSshMethods._requestCloseTab(int i) → Future<void>`.

- [ ] **Step 1: Thread `onOpenEditorTab` through `SshSessionView`**

In `lib/views/ssh_session_view.dart`, add the field and constructor parameter (currently lines 13-26):

```dart
class SshSessionView extends StatefulWidget {
  const SshSessionView({
    super.key,
    required this.sftp,
    required this.host,
    required this.remotePath,
    required this.transferManager,
    required this.sftpVisible,
    required this.onToggleSftp,
    required this.child,
    this.initialPosition = SftpPanelPosition.bottom,
    this.initialSize,
    this.onLayoutChanged,
    this.onOpenEditorTab,
  });

  /// Default SFTP panel share of the session area (2/5 of width or height).
  static const defaultPanelFraction = 2 / 5;

  final SftpClient sftp;
  final String host;
  final ValueNotifier<String> remotePath;
  final TransferManager transferManager;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final Widget child;
  final SftpPanelPosition initialPosition;
  final double? initialSize;
  final void Function(SftpPanelPosition position, double? size)? onLayoutChanged;

  /// Forwarded straight through to the embedded [SftpView] — see its
  /// doc comment for the contract.
  final void Function({
    required String path,
    required String initialContent,
    required DateTime? mtime,
  })? onOpenEditorTab;

  @override
  State<SshSessionView> createState() => _SshSessionViewState();
}
```

Pass it through to `SftpView` — modify the construction (currently lines 79-92):

```dart
        final sftp = SftpView(
          key: _sftpKey,
          sftp: widget.sftp,
          host: widget.host,
          remotePath: widget.remotePath,
          transferManager: widget.transferManager,
          panelPosition: _position,
          onPanelPositionChanged: (pos) => setState(() {
            _position = pos;
            _customPanelSize = null;
            widget.onLayoutChanged?.call(_position, null);
          }),
          onClose: widget.onToggleSftp,
          onOpenEditorTab: widget.onOpenEditorTab,
        );
```

- [ ] **Step 2: Add `_openEditorTab` and `_requestCloseTab` to `main_ssh.dart`**

In `lib/app/main_ssh.dart`, add both methods right after `_closeTab` (currently ending at line 612, before `_selectTab`):

```dart
  /// Opens a new editor tab for a file read from [sourceTab]'s SFTP
  /// panel. Inserted and activated the same way `_newLocalTab` inserts a
  /// fresh local tab (append + activate) — see `main_local.dart`.
  void _openEditorTab({
    required _Tab sourceTab,
    required String path,
    required String initialContent,
    required DateTime? mtime,
  }) {
    final sftp = sourceTab.sftp;
    if (sftp == null) return; // source tab's SFTP session isn't live
    setState(() {
      _tabs.add(_Tab.editor(
        path: path,
        sftp: sftp,
        label: 'ssh: ${sourceTab.title}',
        mtime: mtime,
        initialContent: initialContent,
      ));
      _active = _tabs.length - 1;
    });
  }

  /// Gate in front of [_closeTab] for tabs that may have unsaved
  /// changes. Every non-editor tab, and every editor tab that ISN'T
  /// dirty, behaves exactly like the old direct `onClose: _closeTab`
  /// wiring — this only adds a confirmation step for the one new case.
  Future<void> _requestCloseTab(int i) async {
    if (i < 0 || i >= _tabs.length) return;
    final tab = _tabs[i];
    if (tab.kind != _TabKind.editor || !tab.editorDirty.value) {
      _closeTab(i);
      return;
    }

    final colors = AppColors.maybeOf(context);
    final decision = await showDialog<_UnsavedChangesDecision>(
      context: context,
      builder: (ctx) => Theme(
        data: Theme.of(context)
            .copyWith(extensions: colors != null ? {colors} : null),
        child: const _UnsavedChangesDialog(),
      ),
    );
    if (!mounted || decision == null || decision == _UnsavedChangesDecision.cancel) {
      return;
    }
    if (decision == _UnsavedChangesDecision.discard) {
      _closeTab(i);
      return;
    }
    // decision == save
    final saved = await tab.editorViewKey.currentState?.save() ?? false;
    if (!mounted || !saved) return;
    _closeTab(i);
  }
```

Add the small dialog + its enum at the bottom of `lib/app/main_ssh.dart` (after the closing brace of `_TerminalHomeSshMethods`, as top-level declarations in this `part of '../main.dart'` file):

```dart
enum _UnsavedChangesDecision { save, discard, cancel }

class _UnsavedChangesDialog extends StatelessWidget {
  const _UnsavedChangesDialog();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final fill = colors?.popup ?? FrostedGlassStyle.menuFillFrosted;
    final fg = colors?.foreground ?? const Color(0xFFD4D4D4);
    final fgDim = colors?.foregroundDim ?? const Color(0xFF8E8E8E);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 380,
        child: PopupSurface(
          color: fill,
          backdropBlur: 20,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Unsaved changes',
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'This file has unsaved changes. Save before closing?',
                  style: TextStyle(color: fgDim, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(
                          context, _UnsavedChangesDecision.cancel),
                      child: Text('Cancel', style: TextStyle(color: fgDim)),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(
                          context, _UnsavedChangesDecision.discard),
                      child: const Text(
                        "Don't Save",
                        style: TextStyle(color: Color(0xFFFF6E67)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(
                          context, _UnsavedChangesDecision.save),
                      child: const Text(
                        'Save',
                        style: TextStyle(color: Color(0xFF2472C8)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

No new import needed for `AppColors`/`PopupSurface`/`FrostedGlassStyle` — `lib/main.dart:45` already has `import 'widgets/frosted_glass.dart';`, and `main_ssh.dart` is `part of '../main.dart'`, so every part file shares that same import scope.

- [ ] **Step 3: Wire the `AppTabKind.editor` case into `_buildPrimaryContent` and pass `onOpenEditorTab`**

In `lib/app/main_views.dart`, add the case to the switch (currently lines 457-488):

```dart
  Widget _buildPrimaryContent(
    _Tab tab, {
    TerminalContextMenuConfig? contextMenu,
  }) {
    return switch (tab.kind) {
      _TabKind.local || _TabKind.ssh => _buildTerminalView(
        tab.terminal!,
        tab.terminalViewKey,
        tab: tab,
        sshPane: 0,
        contextMenu: contextMenu,
      ),
      _TabKind.sshConnecting => _buildConnectingBody(tab),
      _TabKind.sshError => _buildErrorBody(tab),
      _TabKind.settings => SettingsPage(
        settings: _config.terminal,
        onChanged: (next) {
          setState(() => _config.terminal = next);
          _config.save();
          _syncAllTerminals();
        },
        savedHosts: _savedHosts,
        onSaveHost: (original, updated) => _saveSavedHost(original, updated),
        onDeleteHost: (host) => _deleteSavedHost(host),
        agent: _config.agent,
        onAgentChanged: (next) {
          setState(() => _config.agent = next);
          _config.save();
        },
      ),
      _TabKind.editor => FileEditorView(
        key: tab.editorViewKey,
        path: tab.editorPath!,
        sftp: tab.editorSftp!,
        label: tab.editorLabel!,
        initialContent: tab.editorInitialContent ?? '',
        initialMtime: tab.editorMtime,
        dirty: tab.editorDirty,
      ),
    };
  }
```

`_buildPrimaryContent` runs on every rebuild, but `FileEditorView.initState` (Task 2) only runs once per widget lifetime — `tab.editorInitialContent` (Task 1) is read here on every rebuild but only ever CONSUMED once, by `initState`, so re-passing the same string on later rebuilds is harmless (it's just an unused constructor argument after the first build).

Add the import at the top of `lib/app/main_views.dart` (near the other `views/` imports — check the existing import block and add alongside it):

```dart
import '../views/file_editor_view.dart';
```

- [ ] **Step 4: Wire `onOpenEditorTab` at the `SshSessionView` construction site and swap `onClose` to `_requestCloseTab`**

In `lib/app/main_views.dart`, modify the `SshSessionView` construction (currently lines 362-378, inside `_buildTabBody`):

```dart
    if (tab.kind == _TabKind.ssh &&
        tab.sftp != null &&
        tab.transferManager != null) {
      body = SshSessionView(
        sftp: tab.sftp!,
        host: tab.title,
        remotePath: tab.remotePath!,
        transferManager: tab.transferManager!,
        sftpVisible: tab.sftpPanelVisible,
        onToggleSftp: () =>
            setState(() => tab.sftpPanelVisible = !tab.sftpPanelVisible),
        initialPosition: _config.sftpPosition,
        initialSize: _config.sftpSize,
        onLayoutChanged: (pos, size) {
          _config.sftpPosition = pos;
          _config.sftpSize = size;
          _config.save();
        },
        onOpenEditorTab: ({required path, required initialContent, required mtime}) =>
            _openEditorTab(
              sourceTab: tab,
              path: path,
              initialContent: initialContent,
              mtime: mtime,
            ),
        child: body,
      );
    }
```

Modify the `_TabBar` construction (currently line 44, inside `_buildChrome`):

```dart
              onClose: _requestCloseTab,
```

- [ ] **Step 5: Run static analysis**

Run: `flutter analyze`
Expected: `No issues found!`. Pay particular attention to any exhaustiveness error on a `switch (tab.kind)`/`switch (someAppTabKind)` this plan didn't anticipate — Task 1's Step 6 already flagged this risk; if one surfaces now, it means Task 1's regression check missed it because the file wasn't part of the compiled set at that point. Fix it by adding the missing `AppTabKind.editor` case, following the same shape as the surrounding cases in that switch.

- [ ] **Step 6: Run the full test suite (regression check)**

Run: `flutter test`
Expected: 421 passed (416 baseline + the 5 tests Task 1 added) / 1 skipped / 1 pre-existing unrelated failure. No new failures.

- [ ] **Step 7: Manual QA**

Launch the app (`flutter run -d macos`), connect to a real SSH host with SFTP, and walk through the 9 scenarios from the spec's Test Plan:

1. Double-click a remote text file → editor tab opens, content correct, path shown in the toolbar.
2. Right-click → "Edit" → same result.
3. Double-click a file over 4 MB → no tab opens, clear error SnackBar.
4. Double-click a binary file → no tab opens, "Not a text file" error.
5. Edit content → dirty dot appears → Cmd/Ctrl+S → dirty dot clears, remote file updated (verify with `cat` from another terminal).
6. Edit without saving, click the tab's close (×) button → confirmation dialog appears; test all three choices (Save / Don't Save / Cancel) behave as expected.
7. Edit the file, then change it from another terminal/machine before saving → Save triggers the mtime-conflict dialog → test both "Overwrite" and "Reload (discard my changes)".
8. Kill the SSH connection while the editor tab is open → Save fails with a clear error, no crash.
9. Double-click a directory row, and a symlink pointing at a directory → both keep navigating into the directory (unchanged behavior), neither opens an editor tab.

- [ ] **Step 8: Commit**

```bash
git add lib/views/ssh_session_view.dart lib/app/main_views.dart lib/app/main_ssh.dart
git commit -m "$(cat <<'EOF'
Wire the SFTP file editor into tabs end-to-end

Threads onOpenEditorTab from SftpView up through SshSessionView to a
new _openEditorTab (appends+activates an AppTabKind.editor tab, same
convention as _newLocalTab). Adds _requestCloseTab, which gates the
tab bar's close button behind a save/discard/cancel dialog only when
an editor tab is dirty — every other tab kind closes exactly as
before. _buildPrimaryContent seeds FileEditorView from
AppTab.editorInitialContent, which initState consumes exactly once.
EOF
)"
```

---

## Post-plan notes

- Mobile (`main_mobile.dart`/`main_mobile_connections.dart`) is untouched by design — its SFTP panel keeps today's behavior. A future plan can extend the mobile action sheet with an "Edit" entry once there's a mobile-appropriate destination for the editor (mobile doesn't have `_TabBar`/`AppTab`-style desktop tabs).
- If a future iteration wants syntax highlighting, that's a separate spec — this plan deliberately ships a plain `TextField` with no highlighting, per the design's explicit MVP scope.
