# File Editor Syntax Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add syntax highlighting and line numbers to ssterm's SFTP file editor (`FileEditorView`) by swapping its plain `TextEditingController`/`TextField` for `flutter_code_editor`'s `CodeController`/`CodeField`, with file-extension-based language detection.

**Architecture:** `CodeController extends TextEditingController`, so it drops into `FileEditorView`'s existing dirty-tracking/save/mtime-conflict machinery with minimal changes — the only real risk is that `CodeController`'s code-folding feature makes `.text` return only the *visible* (unfolded) text, so every place that reads the buffer for saving or dirty-comparison must read `.fullText` instead, or a folded save would silently drop content. A new pure function maps a file path's extension to a `package:highlight` language `Mode`.

**Tech Stack:** Flutter/Dart 3, `flutter_code_editor` (MIT, wraps `package:highlight` + `package:flutter_highlight`).

**Reference spec:** [docs/superpowers/specs/2026-07-21-file-editor-syntax-highlighting-design.md](../specs/2026-07-21-file-editor-syntax-highlighting-design.md)

**API surface used below was verified directly against the installed package source** (`~/.pub-cache/hosted/pub.dev/flutter_code_editor-0.3.5`, `highlight-0.7.0`, `flutter_highlight-0.7.0`) — every constructor/field/import named in this plan exists exactly as written. One correction versus the spec's assumption: the spec said `_reload()`'s `_controller.text = content` reassignment "will be handled correctly" by `CodeController` — verified false. `CodeController` does NOT override the `text` getter/setter (only `fullText` goes through its folding-aware `Code` model), so `_reload()` must also be changed to assign `fullText`, not `text`, to avoid leaving stale fold-block bookkeeping around after a full-content replace. This plan uses `fullText` in all four places the buffer is read or replaced, not just the three the spec named.

## Global Constraints

- No local/hand-rolled multi-language lexer — use `flutter_code_editor` (already decided in brainstorming).
- Language detection is extension-based only, case-insensitive; unrecognized extensions fall back to plain (uncolored) text — never an error.
- Every place `FileEditorViewState` reads the current buffer content (dirty-check, `save()`, `_resolveConflict()`) OR replaces it wholesale (`_reload()`) must use `CodeController.fullText`, never `.text` — folding must never cause silently-lost content.
- Fixed dark theme (`atomOneDarkTheme` from `flutter_highlight`), no user-configurable theme.
- No new Settings toggle.
- No new automated test infrastructure for `FileEditorView` itself (matches this project's established convention — zero tests for chat-card/editor widgets). The one NEW piece of pure, testable logic (the extension→language mapping function) gets real unit tests, per the spec.

---

### Task 1: Language detection + dependency

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/views/file_editor_language.dart`
- Test: `test/views/file_editor_language_test.dart`

**Interfaces:**
- Produces: `Mode? codeEditorLanguageForPath(String path)` — returns a `package:highlight` `Mode` for the file's extension, or `null` when unrecognized. Task 2 imports and calls this from `FileEditorViewState.initState`.

- [ ] **Step 1: Add the dependencies**

Run:
```bash
flutter pub add flutter_code_editor highlight flutter_highlight
```
This adds all three as direct dependencies in `pubspec.yaml` (declaring `highlight`/`flutter_highlight` directly — not just relying on them as `flutter_code_editor`'s transitive deps — since this plan's code imports from both packages directly). Confirm `flutter_code_editor: ^0.3.5` (or whatever current-compatible version `pub` resolves) landed in `pubspec.yaml`'s `dependencies:` section alongside `highlight: ^0.7.0` and `flutter_highlight: ^0.7.0`.

- [ ] **Step 2: Write the failing tests**

Create `test/views/file_editor_language_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight_core.dart';
import 'package:ssterm/views/file_editor_language.dart';

void main() {
  group('codeEditorLanguageForPath', () {
    test('recognizes common extensions', () {
      final cases = <String, String>{
        '/tmp/x.dart': 'dart',
        '/tmp/x.py': 'python',
        '/tmp/x.js': 'javascript',
        '/tmp/x.mjs': 'javascript',
        '/tmp/x.cjs': 'javascript',
        '/tmp/x.ts': 'typescript',
        '/tmp/x.json': 'json',
        '/tmp/x.yaml': 'yaml',
        '/tmp/x.yml': 'yaml',
        '/tmp/x.sh': 'bash',
        '/tmp/x.bash': 'bash',
        '/tmp/x.zsh': 'bash',
        '/tmp/x.md': 'markdown',
        '/tmp/x.markdown': 'markdown',
        '/tmp/x.html': 'xml',
        '/tmp/x.htm': 'xml',
        '/tmp/x.xml': 'xml',
        '/tmp/x.css': 'css',
        '/tmp/x.sql': 'sql',
        '/tmp/x.toml': 'ini',
        '/tmp/x.conf': 'ini',
        '/tmp/x.ini': 'ini',
        '/tmp/x.cfg': 'ini',
        '/tmp/x.go': 'go',
        '/tmp/x.rs': 'rust',
        '/tmp/x.java': 'java',
        '/tmp/x.c': 'cpp',
        '/tmp/x.h': 'cpp',
        '/tmp/x.cpp': 'cpp',
        '/tmp/x.cc': 'cpp',
        '/tmp/x.hpp': 'cpp',
      };
      for (final entry in cases.entries) {
        final mode = codeEditorLanguageForPath(entry.key);
        expect(mode, isNotNull, reason: '${entry.key} should resolve');
        expect(
          identical(mode, allLanguages[entry.value]),
          isTrue,
          reason:
              '${entry.key} should resolve to the SAME Mode instance as '
              "allLanguages['${entry.value}'], not just an equal-looking one",
        );
      }
    });

    test('is case-insensitive', () {
      final lower = codeEditorLanguageForPath('/tmp/x.py');
      final upper = codeEditorLanguageForPath('/tmp/X.PY');
      expect(identical(lower, upper), isTrue);
    });

    test('returns null for an unrecognized extension', () {
      expect(codeEditorLanguageForPath('/tmp/x.foobar'), isNull);
    });

    test('returns null for a path with no extension', () {
      expect(codeEditorLanguageForPath('/tmp/Makefile'), isNull);
    });

    test('returns null for a path ending in a bare dot', () {
      expect(codeEditorLanguageForPath('/tmp/x.'), isNull);
    });

    test('returns null for a dotfile with no further extension '
        '(e.g. ".bashrc")', () {
      // The LAST dot is what matters — ".bashrc" has its only dot at
      // index 0, so `substring(dot + 1)` is "bashrc", which isn't a
      // key in the extension map (only "bash"/"sh"/"zsh" are). This
      // pins that a leading dotfile name isn't accidentally treated
      // as its own "extension".
      expect(codeEditorLanguageForPath('/tmp/.bashrc'), isNull);
    });
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test test/views/file_editor_language_test.dart`
Expected: FAIL — `Error when reading 'lib/views/file_editor_language.dart'` (file doesn't exist yet).

- [ ] **Step 4: Implement `lib/views/file_editor_language.dart`**

```dart
import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/all.dart' show allLanguages;

/// Maps a file extension to the `package:highlight` language-name key
/// used in [allLanguages]. Extensions not listed here fall back to
/// plain, uncolored text in the editor — never an error.
const _kExtensionToHighlightName = <String, String>{
  'dart': 'dart',
  'py': 'python',
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'sh': 'bash',
  'bash': 'bash',
  'zsh': 'bash',
  'md': 'markdown',
  'markdown': 'markdown',
  'html': 'xml',
  'htm': 'xml',
  'xml': 'xml',
  'css': 'css',
  'sql': 'sql',
  'toml': 'ini',
  'conf': 'ini',
  'ini': 'ini',
  'cfg': 'ini',
  'go': 'go',
  'rs': 'rust',
  'java': 'java',
  'c': 'cpp',
  'h': 'cpp',
  'cpp': 'cpp',
  'cc': 'cpp',
  'hpp': 'cpp',
};

/// Returns the `package:highlight` [Mode] for [path]'s extension
/// (case-insensitive), or `null` when the extension is missing or not
/// recognized — the editor then shows plain, uncolored text.
///
/// Matches on the LAST `.` in the path, so a dotfile with no further
/// extension (e.g. `.bashrc`) correctly returns `null` rather than
/// treating "bashrc" as an extension.
Mode? codeEditorLanguageForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  final ext = path.substring(dot + 1).toLowerCase();
  final name = _kExtensionToHighlightName[ext];
  if (name == null) return null;
  return allLanguages[name];
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/views/file_editor_language_test.dart`
Expected: PASS — all 6 tests green.

- [ ] **Step 6: Run the full test suite (regression check)**

Run: `flutter test`
Expected: baseline count + 6 new tests, no new failures. Current baseline going into this plan: 423 passed / 1 skipped / 1 pre-existing unrelated failure (`test/services/local_pty_env_test.dart` — Windows-only test polluted by macOS host PATH, already known, user confirmed to ignore, not this feature's concern).

- [ ] **Step 7: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/views/file_editor_language.dart test/views/file_editor_language_test.dart
git commit -m "$(cat <<'EOF'
Add flutter_code_editor dependency and extension-based language detection

New pure function codeEditorLanguageForPath maps a file's extension to
a package:highlight Mode (or null for unrecognized extensions, which
the editor renders as plain uncolored text). Not wired into
FileEditorView yet — that's the next commit.
EOF
)"
```

---

### Task 2: Wire CodeController/CodeField into FileEditorView

**Files:**
- Modify: `lib/views/file_editor_view.dart`

**Interfaces:**
- Consumes: `codeEditorLanguageForPath` (Task 1).
- No public interface changes — `FileEditorView`'s constructor and `FileEditorViewState.save()` keep their exact existing signatures (Task 4 of the original SFTP-editor plan, and `AppTab.editorViewKey`, depend on these staying stable).

This task is a full-file replacement of `lib/views/file_editor_view.dart`'s current contents (388 lines) with the highlighted version. The diff is large but mechanical: swap the controller type, swap the text-reading calls, swap the input widget, add the theme wrapper. Every other method (`_resolveConflict`, `_humanSaveError`, `_ConflictDialog`, the toolbar, the error bar) is copied verbatim from the current file — only what's called out below actually changes.

- [ ] **Step 1: Replace the file**

Replace the entire contents of `lib/views/file_editor_view.dart`:

```dart
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';

import '../services/file_write_service.dart';
import '../widgets/frosted_glass.dart';
import 'file_editor_language.dart';

const _kBg = Color(0xFF1E1E1E);
const _kToolbar = Color(0x66252525);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgDim = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);
const _kDanger = Color(0xFFFF6E67);

/// Syntax-highlighted editor tab for a remote file opened from the SFTP
/// panel. I/O goes entirely through [SftpFileSystemAdapter] — no AI
/// Agent involvement, no LLM-facing envelopes; every error string here
/// is written for a human reading the toolbar.
///
/// Highlighting/line-numbers/folding come from `flutter_code_editor`'s
/// [CodeController] (a [TextEditingController] subclass) and [CodeField].
/// IMPORTANT: [CodeController.text] returns only the VISIBLE text when
/// code is folded — every place below that reads or replaces the full
/// buffer uses [CodeController.fullText] instead, so a folded save (or
/// a reload) can never silently drop the folded-away content.
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
  /// used once, in [State.initState], to seed the [CodeController].
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
  late final CodeController _controller;
  late String _originalContent;
  DateTime? _mtime;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = CodeController(
      text: widget.initialContent,
      language: codeEditorLanguageForPath(widget.path),
    );
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
    final isDirty = _controller.fullText != _originalContent;
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
        _controller.fullText,
        expectedMtime: _mtime,
      );
      if (!mounted) return true;
      setState(() {
        _originalContent = _controller.fullText;
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
        final result =
            await _adapter.commit(widget.path, _controller.fullText);
        if (!mounted) return true;
        setState(() {
          _originalContent = _controller.fullText;
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
        // fullText (not text) — a plain `.text =` assignment would
        // bypass CodeController's folding-aware Code model and could
        // leave stale fold-block bookkeeping pointing at line numbers
        // that no longer make sense after this full-content replace.
        _controller.fullText = content;
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
                  child: CodeTheme(
                    data: CodeThemeData(styles: atomOneDarkTheme),
                    child: SingleChildScrollView(
                      child: CodeField(
                        controller: _controller,
                        expands: false,
                        textStyle: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
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
            builder: (_, dirty, _) => Container(
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

Note on `CodeField`'s `expands`/scrolling: unlike the old plain `TextField(maxLines: null, expands: true, ...)` (which filled the `Expanded` parent and scrolled internally), `CodeField` is wrapped here in a `SingleChildScrollView` with `expands: false` — `CodeField` lays out its gutter (line numbers) and code area as an intrinsic-height column that doesn't itself support Flutter's `expands: true` cleanly alongside a gutter, so it needs an external scroll view. This still fills the available width (the `Expanded`/`Padding` ancestors are unchanged) and scrolls vertically for files taller than the viewport — behaviorally equivalent to the old always-scrollable `TextField` for the user.

- [ ] **Step 2: Run static analysis**

Run: `flutter analyze lib/views/file_editor_view.dart`
Expected: `No issues found!`

- [ ] **Step 3: Run the full test suite (regression check)**

Run: `flutter test`
Expected: same counts as the end of Task 1 (no new tests from this task — matches the project's convention of no automated tests for this widget). No new failures.

- [ ] **Step 4: Manual QA**

Launch the app (`flutter run -d macos`), connect to a real SSH host, and re-run the relevant parts of the SFTP file editor's existing manual QA checklist (see [docs/superpowers/plans/2026-07-20-sftp-file-editor.md](2026-07-20-sftp-file-editor.md)'s Task 4 Step 7) to confirm highlighting didn't break anything already shipped, PLUS the new highlighting-specific checks:

1. Open a `.py`/`.yaml`/`.sh`/`.json` file → keywords/strings/comments show distinct colors; line numbers appear on the left.
2. Open a file with an unrecognized extension (e.g. `.foobar`) → opens fine, edits fine, just no coloring — no error, no crash.
3. Edit → dirty dot appears → Cmd/Ctrl+S → dirty dot clears, "Saved" toast, remote file actually updated (verify with `cat` from another terminal) — confirms the `.fullText`-based save still works correctly.
4. Trigger an mtime conflict (edit locally, change the same file from another terminal, then Save) → conflict dialog appears, both "Overwrite" and "Reload" still work correctly.
5. Edit without saving, close via the tab bar's (×) AND via Cmd+W → both still show the Save/Don't Save/Cancel confirmation (this was the bug fixed in the previous plan — confirm the highlighting change didn't regress it).
6. If the editor exposes a way to fold a block of code (check the gutter for a fold icon/handle — `flutter_code_editor` enables this by default): fold a block, then Save → `cat` the remote file from another terminal and confirm the FULL content (including the folded-away lines) is present, not truncated. This is the single most important check in this plan — it's the concrete proof that the `.fullText` correctness fix actually works.

- [ ] **Step 5: Commit**

```bash
git add lib/views/file_editor_view.dart
git commit -m "$(cat <<'EOF'
Wire syntax highlighting into FileEditorView

Swaps TextEditingController/TextField for flutter_code_editor's
CodeController/CodeField, seeded with a language Mode from
codeEditorLanguageForPath. Every read or wholesale replacement of the
buffer (dirty-check, save(), _resolveConflict(), and _reload() — the
last one wasn't called out by the spec but needed the same fix) now
goes through CodeController.fullText instead of .text, so code
folding can never cause a save to silently drop content. Toolbar,
Cmd/Ctrl+S, mtime-conflict dialog, and close-confirmation wiring are
untouched.
EOF
)"
```

---

## Post-plan notes

- Code folding is left at its package default (enabled) per the spec's explicit decision not to proactively disable it — safety is guaranteed by the `.fullText` fix, not by hiding the feature.
- No new Settings toggle, no custom theme picker — matches the spec's stated non-goals.
- If a future iteration wants search/replace, autocomplete tuning, or a configurable theme, those are separate specs — `flutter_code_editor` may already partially support some of this out of the box, but this plan doesn't enable/tune any of it beyond what's needed for highlighting + line numbers.
