# edit_file Precise-Editing Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `edit_file` structured tool call to ssterm's AI agent that lets the model propose a targeted search/replace edit (instead of a whole-file overwrite), shown to the user as a line-level diff Apply/Reject card, and committed through the same atomic-write path `write_file` already uses.

**Architecture:** New tool call parsing in `LlmService.ToolCall` (mirrors `write_file`), a new `FileSystemAdapter.readContent` capability so ssterm can locate `old_string` in the live file, a new pure `FileEditService` for match/replace semantics, a new pure line-level LCS diff utility, and a new `_EditProposal`/`_EditProposalCard` pair that plugs into the existing agent-loop pause/resume machinery the same way `_WriteProposal` does.

**Tech Stack:** Flutter/Dart 3, `flutter_test` for unit tests. No new package dependencies.

**Reference spec:** [docs/superpowers/specs/2026-07-20-edit-file-tool-design.md](../specs/2026-07-20-edit-file-tool-design.md)

## Global Constraints

- No new pub dependencies — the line-diff algorithm is hand-rolled (project has zero diff-related packages today).
- `edit_file` is gated by the EXISTING `AgentConfig.fileWriteEnabled` toggle — do not add a new Settings field.
- `old_string`/`new_string` matching is literal (no regex/fuzzy matching).
- One `edit_file` proposal per model turn — no batched multi-edit.
- Files larger than 4 MB (`_maxEditableSize`) are refused by `readContent` — same threshold `preview()` already uses for line counting.
- Match validation (no-match / ambiguous-match) happens BEFORE the diff card is shown — a doomed edit never reaches the UI.
- No new loop/widget-level test infrastructure — this project has no tests for `ai_assistant_panel_loop.dart` or any chat-card widget today, and this feature doesn't add any. Pure-Dart logic (diff algorithm, match service, adapter, protocol parsing) IS unit tested.

---

### Task 1: Line-level diff utility

**Files:**
- Create: `lib/utils/line_diff.dart`
- Test: `test/utils/line_diff_test.dart`

**Interfaces:**
- Produces: `enum DiffLineKind { equal, added, removed }`; `class DiffLine { final DiffLineKind kind; final String text; final int? oldLineNo; final int? newLineNo; }`; `List<DiffLine> computeLineDiff(String oldText, String newText, {int maxCells = 4000000})`.

- [ ] **Step 1: Write the failing tests**

Create `test/utils/line_diff_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/utils/line_diff.dart';

void main() {
  group('computeLineDiff', () {
    test('identical text produces only equal lines', () {
      const text = 'a\nb\nc';
      final diff = computeLineDiff(text, text);
      expect(diff, hasLength(3));
      expect(diff.every((l) => l.kind == DiffLineKind.equal), isTrue);
      expect(diff[0].oldLineNo, equals(1));
      expect(diff[0].newLineNo, equals(1));
      expect(diff[2].text, equals('c'));
    });

    test('pure insertion — new lines appear as added, old lines stay equal',
        () {
      final diff = computeLineDiff('a\nc', 'a\nb\nc');
      expect(diff.map((l) => l.kind), equals([
        DiffLineKind.equal,
        DiffLineKind.added,
        DiffLineKind.equal,
      ]));
      expect(diff[1].text, equals('b'));
      expect(diff[1].oldLineNo, isNull);
      expect(diff[1].newLineNo, equals(2));
    });

    test('pure deletion — removed line has no newLineNo', () {
      final diff = computeLineDiff('a\nb\nc', 'a\nc');
      expect(diff.map((l) => l.kind), equals([
        DiffLineKind.equal,
        DiffLineKind.removed,
        DiffLineKind.equal,
      ]));
      expect(diff[1].text, equals('b'));
      expect(diff[1].oldLineNo, equals(2));
      expect(diff[1].newLineNo, isNull);
    });

    test('single-line replacement shows as removed+added, not a mystery '
        'equal line', () {
      final diff = computeLineDiff('hello world', 'hello dart');
      expect(diff, hasLength(2));
      expect(diff[0].kind, equals(DiffLineKind.removed));
      expect(diff[0].text, equals('hello world'));
      expect(diff[1].kind, equals(DiffLineKind.added));
      expect(diff[1].text, equals('hello dart'));
    });

    test('change at the very first and very last line', () {
      final diff = computeLineDiff('old1\nmid\nold3', 'new1\nmid\nnew3');
      expect(diff.map((l) => l.kind), equals([
        DiffLineKind.removed,
        DiffLineKind.added,
        DiffLineKind.equal,
        DiffLineKind.removed,
        DiffLineKind.added,
      ]));
    });

    test('a single trailing newline does not create a phantom empty line',
        () {
      final diff = computeLineDiff('a\nb\n', 'a\nb\n');
      expect(diff, hasLength(2));
    });

    test('empty old text is entirely additions', () {
      final diff = computeLineDiff('', 'a\nb');
      expect(diff, hasLength(2));
      expect(diff.every((l) => l.kind == DiffLineKind.added), isTrue);
    });

    test('empty new text is entirely removals', () {
      final diff = computeLineDiff('a\nb', '');
      expect(diff, hasLength(2));
      expect(diff.every((l) => l.kind == DiffLineKind.removed), isTrue);
    });

    test('inputs whose cell count exceeds maxCells fall back to a coarse '
        'remove-all-then-add-all diff instead of hanging', () {
      // Force the fallback with a tiny maxCells so the test stays fast —
      // production default (4,000,000) only triggers on genuinely huge
      // files, which we don't want to allocate in a unit test.
      final diff = computeLineDiff('a\nb\nc', 'x\ny', maxCells: 2);
      expect(diff.map((l) => l.kind), equals([
        DiffLineKind.removed,
        DiffLineKind.removed,
        DiffLineKind.removed,
        DiffLineKind.added,
        DiffLineKind.added,
      ]));
      expect(diff[0].text, equals('a'));
      expect(diff[3].text, equals('x'));
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/utils/line_diff_test.dart`
Expected: FAIL — `Error: Error when reading 'lib/utils/line_diff.dart': No such file or directory` (or an unresolved-import compile error).

- [ ] **Step 3: Implement `lib/utils/line_diff.dart`**

```dart
/// Kind of a single line in a computed diff.
enum DiffLineKind { equal, added, removed }

/// One line of a computed diff between two texts.  See [computeLineDiff].
class DiffLine {
  final DiffLineKind kind;
  final String text;

  /// 1-based line number in the OLD text.  Null for [DiffLineKind.added]
  /// lines, which don't exist in the old text.
  final int? oldLineNo;

  /// 1-based line number in the NEW text.  Null for
  /// [DiffLineKind.removed] lines, which don't exist in the new text.
  final int? newLineNo;

  const DiffLine({
    required this.kind,
    required this.text,
    this.oldLineNo,
    this.newLineNo,
  });
}

/// Computes a line-level diff between [oldText] and [newText] using the
/// classic longest-common-subsequence (LCS) algorithm.  Splits both
/// inputs on `\n`; a single trailing newline (the text ends with `\n`)
/// does NOT produce a trailing empty line in the output — matches how
/// most editors treat a POSIX-style final newline as "not a line".
///
/// O(n*m) time/space in the input line counts, which is fine for the
/// file sizes `edit_file` operates on in the common case (a few hundred
/// to a few thousand lines).  A large file with many short lines could
/// still produce a huge `n*m` even under the 4 MB size cap
/// `FileSystemAdapter.readContent` enforces, so when the DP table would
/// exceed [maxCells] we skip it entirely and return a coarse
/// "everything removed, then everything added" diff instead of
/// allocating an unbounded table — still correct (the new content is
/// exactly [newText]), just not minimal.
List<DiffLine> computeLineDiff(
  String oldText,
  String newText, {
  int maxCells = 4000000,
}) {
  final oldLines = _splitLines(oldText);
  final newLines = _splitLines(newText);
  final n = oldLines.length;
  final m = newLines.length;

  if (n * m > maxCells) {
    return [
      for (var k = 0; k < n; k++)
        DiffLine(kind: DiffLineKind.removed, text: oldLines[k], oldLineNo: k + 1),
      for (var k = 0; k < m; k++)
        DiffLine(kind: DiffLineKind.added, text: newLines[k], newLineNo: k + 1),
    ];
  }

  // lcs[i][j] = length of the LCS of oldLines[i:] and newLines[j:].
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = oldLines[i] == newLines[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final result = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      result.add(DiffLine(
        kind: DiffLineKind.equal,
        text: oldLines[i],
        oldLineNo: i + 1,
        newLineNo: j + 1,
      ));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      result.add(DiffLine(
        kind: DiffLineKind.removed,
        text: oldLines[i],
        oldLineNo: i + 1,
      ));
      i++;
    } else {
      result.add(DiffLine(
        kind: DiffLineKind.added,
        text: newLines[j],
        newLineNo: j + 1,
      ));
      j++;
    }
  }
  while (i < n) {
    result.add(DiffLine(
      kind: DiffLineKind.removed,
      text: oldLines[i],
      oldLineNo: i + 1,
    ));
    i++;
  }
  while (j < m) {
    result.add(DiffLine(
      kind: DiffLineKind.added,
      text: newLines[j],
      newLineNo: j + 1,
    ));
    j++;
  }
  return result;
}

List<String> _splitLines(String text) {
  if (text.isEmpty) return const [];
  final body = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  if (body.isEmpty) return const [];
  return body.split('\n');
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/utils/line_diff_test.dart`
Expected: PASS — 9 tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/utils/line_diff.dart test/utils/line_diff_test.dart
git commit -m "$(cat <<'EOF'
Add a hand-rolled line-level LCS diff utility

Pure Dart, no new dependency. Used by the upcoming edit_file diff
card. Falls back to a coarse remove-all/add-all diff above a cell-count
threshold so a large file can't blow up the O(n*m) DP table.
EOF
)"
```

---

### Task 2: `FileSystemAdapter.readContent` + `tooLarge` error kind

**Files:**
- Modify: `lib/services/file_write_service.dart`
- Test: `test/services/file_write_service_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `FileSystemAdapter.readContent(String path) → Future<String>`; `FileWriteErrorKind.tooLarge`; top-level `const _maxEditableSize = 4 * 1024 * 1024;` (file-private).

- [ ] **Step 1: Write the failing tests**

Add to `test/services/file_write_service_test.dart`, inside `void main() { ... }`, as new groups (place after the existing `group('LocalFileSystemAdapter.commit', ...)` block and before `group('SftpFileSystemAdapter availability', ...)`):

```dart
  group('LocalFileSystemAdapter.readContent', () {
    late Directory tempRoot;
    late LocalFileSystemAdapter adapter;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('ssterm-fw-read-');
      adapter = const LocalFileSystemAdapter();
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('reads back exactly what was written', () async {
      final path = '${tempRoot.path}/x.txt';
      File(path).writeAsStringSync('line1\nline2\n');
      expect(await adapter.readContent(path), equals('line1\nline2\n'));
    });

    test('throws io when the file does not exist', () async {
      await expectLater(
        () => adapter.readContent('${tempRoot.path}/missing.txt'),
        throwsA(isA<FileWriteException>()
            .having((e) => e.kind, 'kind', equals(FileWriteErrorKind.io))),
      );
    });

    test('throws tooLarge above the 4 MB edit limit', () async {
      final path = '${tempRoot.path}/big.txt';
      // One byte over 4 MiB — cheap to allocate, no need to actually
      // hit a realistic multi-MB text file.
      File(path).writeAsBytesSync(List.filled(4 * 1024 * 1024 + 1, 65));
      await expectLater(
        () => adapter.readContent(path),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind,
          'kind',
          equals(FileWriteErrorKind.tooLarge),
        )),
      );
    });

    test('throws io for non-UTF-8 binary content', () async {
      final path = '${tempRoot.path}/binary.dat';
      File(path).writeAsBytesSync([0xFF, 0xFE, 0x00, 0xD8, 0x00, 0x00]);
      await expectLater(
        () => adapter.readContent(path),
        throwsA(isA<FileWriteException>()
            .having((e) => e.kind, 'kind', equals(FileWriteErrorKind.io))),
      );
    });
  });
```

Add to the existing `group('SftpFileSystemAdapter availability', ...)` block (right after the existing `test('commit throws notSupported when sftp is null', ...)` test):

```dart
    test('readContent throws notSupported when sftp is null', () async {
      final adapter = SftpFileSystemAdapter(sftp: null, label: 'ssh: dead');
      await expectLater(
        () => adapter.readContent('/etc/hosts'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind,
          'kind',
          equals(FileWriteErrorKind.notSupported),
        )),
      );
    });
```

Add to the existing `group('FileWriteService formatters', ...)` block (right after the `test('parentMissing recovery suggests mkdir -p (concrete fix)', ...)` test):

```dart
    test('tooLarge recovery points at sed/awk (concrete fallback)', () {
      final out = FileWriteService.formatErrorForLlm(
        '/a/big.log',
        const FileWriteException(FileWriteErrorKind.tooLarge, 'too big'),
      );
      expect(out, contains('sed'));
    });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/services/file_write_service_test.dart`
Expected: FAIL — `The method 'readContent' isn't defined for the type 'LocalFileSystemAdapter'` (and similarly for `SftpFileSystemAdapter`), plus `Undefined name 'tooLarge'`.

- [ ] **Step 3: Add `_maxEditableSize`, the `tooLarge` kind, and the abstract method**

In `lib/services/file_write_service.dart`, add a top-level constant right after the imports (before the `FileWriteErrorKind` enum, currently starting at line 14):

```dart
/// Files larger than this are refused by [FileSystemAdapter.readContent]
/// — `edit_file` needs the full content in memory to locate `old_string`
/// and diff it; anything bigger should go through `sed`/`awk` instead.
const _maxEditableSize = 4 * 1024 * 1024;
```

In the `FileWriteErrorKind` enum, add a new value after `notSupported` (the last current member, around line 41):

```dart
  /// Adapter explicitly refuses to handle the request — used by the
  /// SFTP adapter when no SSH session is available, and by the local
  /// adapter when the tab is remote.  Translated into a "use bash
  /// heredoc as a fallback" hint for the model.
  notSupported,

  /// File exceeds [_maxEditableSize] — too large to safely load into
  /// memory for an `edit_file` match/replace.  The model is told to
  /// fall back to `sed`/`awk` via bash.
  tooLarge,
```

In the abstract `FileSystemAdapter` class (`file_write_service.dart:132-188`), add a new method right after the `commit` method's closing brace (before the class's closing brace):

```dart
  /// Read the full current content of [path] as UTF-8 text.  Used by
  /// `edit_file` to locate `old_string` before computing a replacement
  /// — unlike [preview], which only reports metadata (size/mtime/line
  /// count), this returns the actual bytes.
  ///
  /// Throws [FileWriteException] with:
  ///   - [FileWriteErrorKind.notSupported]: adapter unavailable (mirrors
  ///     [preview]/[commit]).
  ///   - [FileWriteErrorKind.invalidPath] / [FileWriteErrorKind.io]: same
  ///     path-resolution and existence failures as [preview].
  ///   - [FileWriteErrorKind.tooLarge]: file exceeds [_maxEditableSize].
  Future<String> readContent(String path);
```

- [ ] **Step 4: Implement `readContent` on `LocalFileSystemAdapter`**

In `LocalFileSystemAdapter` (`file_write_service.dart:195-417`), add the method right after `preview` (before `commit`):

```dart
  @override
  Future<String> readContent(String path) async {
    final resolved = _resolvePath(path);
    final f = File(resolved);
    if (!await f.exists()) {
      throw FileWriteException(
        FileWriteErrorKind.io,
        'File does not exist: $resolved',
      );
    }
    final stat = await f.stat();
    if (stat.size > _maxEditableSize) {
      throw FileWriteException(
        FileWriteErrorKind.tooLarge,
        'File is ${stat.size} bytes, exceeds the $_maxEditableSize byte '
        'edit limit: $resolved',
      );
    }
    try {
      return await f.readAsString();
    } on FormatException {
      throw FileWriteException(
        FileWriteErrorKind.io,
        'File is not valid UTF-8 text, cannot edit in place: $resolved',
      );
    }
  }
```

- [ ] **Step 5: Implement `readContent` on `SftpFileSystemAdapter`**

In `SftpFileSystemAdapter` (`file_write_service.dart:430-754`), add the method right after `preview` (before `commit`):

```dart
  @override
  Future<String> readContent(String path) async {
    final client = sftp;
    if (client == null) {
      throw const FileWriteException(
        FileWriteErrorKind.notSupported,
        'SSH session is not connected yet.',
      );
    }
    final resolved = await _resolveRemotePath(path);
    SftpFileAttrs attrs;
    try {
      attrs = await client.stat(resolved);
    } on SftpStatusError catch (e) {
      if (e.code == 2) {
        throw FileWriteException(
          FileWriteErrorKind.io,
          'File does not exist on the remote: $resolved',
        );
      }
      throw FileWriteException(
        FileWriteErrorKind.io,
        'SFTP stat failed: ${e.message}',
      );
    }
    final size = attrs.size ?? 0;
    if (size > _maxEditableSize) {
      throw FileWriteException(
        FileWriteErrorKind.tooLarge,
        'File is $size bytes, exceeds the $_maxEditableSize byte edit '
        'limit: $resolved',
      );
    }
    final remote = await client.open(resolved);
    try {
      final bytes = await remote.readBytes();
      try {
        return utf8.decode(bytes);
      } on FormatException {
        throw FileWriteException(
          FileWriteErrorKind.io,
          'File is not valid UTF-8 text, cannot edit in place: $resolved',
        );
      }
    } finally {
      await remote.close();
    }
  }
```

- [ ] **Step 6: Add the `tooLarge` recovery hint**

In `FileWriteService.formatErrorForLlm` (`file_write_service.dart:791-811`), add a case to the `switch` right after the `notSupported` case:

```dart
      FileWriteErrorKind.notSupported =>
        'This adapter cannot handle the write (the SSH session may not be ready, or the path scheme is unsupported). Fall back to `cat <<EOF > path` via bash.',
      FileWriteErrorKind.tooLarge =>
        'File too large to edit in-place (> 4 MB). Use `sed`/`awk` via bash for large files, or read a smaller slice with `head`/`grep -n`/`sed -n` to confirm the exact old_string before retrying with a NARROWER match.',
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `flutter test test/services/file_write_service_test.dart`
Expected: PASS — all groups green, including the new `readContent` groups and the `tooLarge` formatter test. The pre-existing `'every error kind has a recovery hint in formatErrorForLlm'` test (which iterates `FileWriteErrorKind.values`) must also still pass — it will automatically cover `tooLarge` since it loops over every enum value.

- [ ] **Step 8: Commit**

```bash
git add lib/services/file_write_service.dart test/services/file_write_service_test.dart
git commit -m "$(cat <<'EOF'
Add FileSystemAdapter.readContent and a tooLarge error kind

edit_file needs the live file content to locate old_string before it
can compute a replacement — preview() only ever exposed metadata.
Reuses the existing 4 MB threshold preview() already applies to line
counting.
EOF
)"
```

---

### Task 3: `FileEditService` — match/replace semantics

**Files:**
- Create: `lib/services/file_edit_service.dart`
- Test: `test/services/file_edit_service_test.dart`

**Interfaces:**
- Consumes: `FileWriteResult` from `lib/services/file_write_service.dart` (already defined — `resolvedPath`, `bytesWritten`, `mtime`, `created`).
- Produces: `enum EditMatchErrorKind { noMatch, ambiguousMatch }`; `class EditMatchException implements Exception { final EditMatchErrorKind kind; final int matchCount; }`; `class EditMatchResult { final String newContent; final int matchCount; }`; `class FileEditService` with static `applyEdit`, `formatNoMatchForLlm`, `formatAmbiguousForLlm`, `formatSuccessForLlm`, `formatRejectionForLlm`.

- [ ] **Step 1: Write the failing tests**

Create `test/services/file_edit_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/file_edit_service.dart';
import 'package:ssterm/services/file_write_service.dart';

void main() {
  group('FileEditService.applyEdit', () {
    test('replaces a unique match', () {
      final result = FileEditService.applyEdit(
        current: 'a\nb\nc\n',
        oldString: 'b',
        newString: 'B',
        replaceAll: false,
      );
      expect(result.newContent, equals('a\nB\nc\n'));
      expect(result.matchCount, equals(1));
    });

    test('throws noMatch with count 0 when old_string is absent', () {
      expect(
        () => FileEditService.applyEdit(
          current: 'a\nb\nc\n',
          oldString: 'zzz',
          newString: 'B',
          replaceAll: false,
        ),
        throwsA(isA<EditMatchException>()
            .having((e) => e.kind, 'kind', equals(EditMatchErrorKind.noMatch))
            .having((e) => e.matchCount, 'matchCount', equals(0))),
      );
    });

    test('throws ambiguousMatch with the real count when replace_all is '
        'false and old_string repeats', () {
      expect(
        () => FileEditService.applyEdit(
          current: 'x\nx\nx\n',
          oldString: 'x',
          newString: 'y',
          replaceAll: false,
        ),
        throwsA(isA<EditMatchException>()
            .having((e) => e.kind, 'kind',
                equals(EditMatchErrorKind.ambiguousMatch))
            .having((e) => e.matchCount, 'matchCount', equals(3))),
      );
    });

    test('replace_all=true replaces every occurrence and reports the '
        'real count', () {
      final result = FileEditService.applyEdit(
        current: 'x\nx\nx\n',
        oldString: 'x',
        newString: 'y',
        replaceAll: true,
      );
      expect(result.newContent, equals('y\ny\ny\n'));
      expect(result.matchCount, equals(3));
    });

    test('replace_all=true with a single occurrence still works', () {
      final result = FileEditService.applyEdit(
        current: 'only\n',
        oldString: 'only',
        newString: 'unique',
        replaceAll: true,
      );
      expect(result.newContent, equals('unique\n'));
      expect(result.matchCount, equals(1));
    });

    test('new_string can be empty (a deletion edit)', () {
      final result = FileEditService.applyEdit(
        current: 'keep-DELETE_ME-keep',
        oldString: 'DELETE_ME',
        newString: '',
        replaceAll: false,
      );
      expect(result.newContent, equals('keep-keep'));
    });

    test('overlapping-looking occurrences are counted non-overlapping, '
        'matching Dart String.replaceAll semantics', () {
      // 'aaaa' contains 'aa' starting at index 0 and 2 under
      // non-overlapping scanning — NOT 3 (which overlapping scanning
      // would report at indices 0,1,2). replace_all must replace
      // exactly what gets counted, so the two numbers can never
      // disagree.
      final result = FileEditService.applyEdit(
        current: 'aaaa',
        oldString: 'aa',
        newString: 'b',
        replaceAll: true,
      );
      expect(result.matchCount, equals(2));
      expect(result.newContent, equals('bb'));
    });
  });

  group('FileEditService LLM envelope formatters', () {
    test('no-match envelope tells the model to re-read the file', () {
      final out = FileEditService.formatNoMatchForLlm('/tmp/x', 'needle');
      expect(out, contains('[File edit failed]'));
      expect(out, contains('reason: no_match'));
      expect(out, contains('Re-read the file'));
    });

    test('ambiguous-match envelope reports the count and the two fixes', () {
      final out =
          FileEditService.formatAmbiguousForLlm('/tmp/x', 'needle', 4);
      expect(out, contains('reason: ambiguous_match'));
      expect(out, contains('4 times'));
      expect(out, contains('replace_all'));
    });

    test('success envelope includes the edit count alongside byte/mtime',
        () {
      final r = FileWriteResult(
        resolvedPath: '/tmp/x',
        bytesWritten: 10,
        created: false,
        mtime: DateTime.utc(2026, 1, 1),
      );
      final out = FileEditService.formatSuccessForLlm(3, r);
      expect(out, contains('[File edited]'));
      expect(out, contains('edits: 3'));
      expect(out, contains('bytes: 10'));
    });

    test('rejection envelope blocks blind retry, same as write_file\'s', () {
      final out = FileEditService.formatRejectionForLlm('/tmp/x',
          reason: 'wrong file');
      expect(out, contains('[File edit rejected by user]'));
      expect(out, contains('wrong file'));
      expect(out, contains('Do NOT re-emit'));
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/services/file_edit_service_test.dart`
Expected: FAIL — `Error when reading 'lib/services/file_edit_service.dart'`.

- [ ] **Step 3: Implement `lib/services/file_edit_service.dart`**

```dart
import 'file_write_service.dart';

/// Why [FileEditService.applyEdit] refused to produce a result.
enum EditMatchErrorKind {
  /// `old_string` does not appear in the current file content at all.
  noMatch,

  /// `old_string` appears more than once and `replace_all` was false —
  /// a single in-place edit needs an unambiguous target.
  ambiguousMatch,
}

class EditMatchException implements Exception {
  final EditMatchErrorKind kind;

  /// 0 for [EditMatchErrorKind.noMatch]; the real occurrence count
  /// (>= 2) for [EditMatchErrorKind.ambiguousMatch].
  final int matchCount;

  const EditMatchException(this.kind, this.matchCount);

  @override
  String toString() => 'EditMatchException(${kind.name}, count=$matchCount)';
}

class EditMatchResult {
  /// Full file content after applying the replacement.
  final String newContent;

  /// How many occurrences were actually replaced — always 1 for a
  /// non-`replace_all` edit, the real count for `replace_all`.
  final int matchCount;

  const EditMatchResult({required this.newContent, required this.matchCount});
}

/// Stateless helpers for the `edit_file` tool: locating `old_string` in
/// a file's current content, producing the replaced text, and
/// formatting the LLM-facing result envelopes.  Mirrors
/// [FileWriteService]'s organisation (pure functions + envelope
/// formatters) so both tools are easy to test the same way.
class FileEditService {
  /// Locate [oldString] in [current] and replace it with [newString].
  ///
  /// - Zero occurrences → throws [EditMatchException] with
  ///   [EditMatchErrorKind.noMatch].
  /// - More than one occurrence AND `replaceAll` is false → throws
  ///   [EditMatchException] with [EditMatchErrorKind.ambiguousMatch]
  ///   (carrying the real count so the caller can report it).
  /// - Otherwise replaces the single match (or every match, when
  ///   `replaceAll` is true) and returns the new full content.
  ///
  /// Occurrence counting is NON-overlapping (same semantics as
  /// [String.replaceAll]) so `matchCount` always agrees with what was
  /// actually replaced.
  static EditMatchResult applyEdit({
    required String current,
    required String oldString,
    required String newString,
    required bool replaceAll,
  }) {
    final count = _countOccurrences(current, oldString);
    if (count == 0) {
      throw const EditMatchException(EditMatchErrorKind.noMatch, 0);
    }
    if (!replaceAll && count > 1) {
      throw EditMatchException(EditMatchErrorKind.ambiguousMatch, count);
    }
    final newContent = replaceAll
        ? current.replaceAll(oldString, newString)
        : current.replaceFirst(oldString, newString);
    return EditMatchResult(
      newContent: newContent,
      matchCount: replaceAll ? count : 1,
    );
  }

  static int _countOccurrences(String haystack, String needle) {
    if (needle.isEmpty) return 0;
    var count = 0;
    var start = 0;
    while (true) {
      final idx = haystack.indexOf(needle, start);
      if (idx < 0) break;
      count++;
      start = idx + needle.length;
    }
    return count;
  }

  static String formatNoMatchForLlm(String path, String oldString) {
    return '[File edit failed]\n'
        'path: $path\n'
        'reason: no_match\n'
        'message: old_string was not found in the current file contents.\n\n'
        'Re-read the file (e.g. `cat -n <path>` or `sed -n` a relevant '
        'range) to confirm the EXACT current text — old_string must match '
        'verbatim, including whitespace and indentation. Do NOT retry the '
        'same edit_file call unchanged.';
  }

  static String formatAmbiguousForLlm(
    String path,
    String oldString,
    int count,
  ) {
    return '[File edit failed]\n'
        'path: $path\n'
        'reason: ambiguous_match\n'
        'message: old_string occurs $count times in the file; a single '
        'in-place edit needs an unambiguous target.\n\n'
        'Either widen old_string with more surrounding context so it '
        'matches exactly once, or re-issue the call with '
        '"replace_all": true to replace all $count occurrences.';
  }

  static String formatSuccessForLlm(int matchCount, FileWriteResult r) {
    final mtime = r.mtime?.toIso8601String() ?? '-';
    return '[File edited]\n'
        'path: ${r.resolvedPath}\n'
        'edits: $matchCount\n'
        'bytes: ${r.bytesWritten}\n'
        'mtime: $mtime';
  }

  static String formatRejectionForLlm(String path, {String? reason}) {
    final why = reason == null || reason.trim().isEmpty
        ? '(no reason given)'
        : reason.trim();
    return '[File edit rejected by user]\n'
        'path: $path\n'
        'reason: $why\n\n'
        'The user declined this edit. Do NOT re-emit the same edit_file '
        'tool call for the same path. Either ask the user what to change, '
        'propose a different edit, or proceed without it.';
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/services/file_edit_service_test.dart`
Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/services/file_edit_service.dart test/services/file_edit_service_test.dart
git commit -m "$(cat <<'EOF'
Add FileEditService for edit_file match/replace semantics

Pure match/replace logic plus the four LLM-facing envelope shapes
(no-match, ambiguous-match, success, rejection), independent of the
agent-loop/UI wiring that will consume it.
EOF
)"
```

---

### Task 4: `ToolCall` protocol additions for `edit_file`

**Files:**
- Modify: `lib/services/llm_service.dart`
- Test: `test/services/llm_service_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ToolCall.isEditFile → bool`; `ToolCall.oldString → String?`; `ToolCall.newString → String?`; `ToolCall.replaceAll → bool`. `_isSupportedToolCall`/`_dedupeToolCalls` updated to recognise `edit_file`.

- [ ] **Step 1: Write the failing tests**

Add to `test/services/llm_service_test.dart`, in the same `group` that contains the existing `'extracts structured write_file calls'` test (around line 281), right after that test:

```dart
    test('extracts structured edit_file calls', () {
      const input = r'''
```tool_call
{"id":"call_edit","name":"edit_file","arguments":{"path":"/tmp/a.txt","old_string":"foo","new_string":"bar","replace_all":true}}
```
''';
      final calls = LlmService.extractToolCalls(input);
      expect(calls.single.isEditFile, isTrue);
      expect(calls.single.path, equals('/tmp/a.txt'));
      expect(calls.single.oldString, equals('foo'));
      expect(calls.single.newString, equals('bar'));
      expect(calls.single.replaceAll, isTrue);
      expect(LlmService.extractCommands(input), isEmpty);
    });

    test('edit_file replace_all defaults to false when omitted', () {
      const input = r'''
```tool_call
{"id":"call_edit","name":"edit_file","arguments":{"path":"/tmp/a.txt","old_string":"foo","new_string":"bar"}}
```
''';
      final calls = LlmService.extractToolCalls(input);
      expect(calls.single.replaceAll, isFalse);
    });

    test('edit_file missing old_string is rejected', () {
      const input = r'''
```tool_call
{"id":"call_edit","name":"edit_file","arguments":{"path":"/tmp/a.txt","new_string":"bar"}}
```
''';
      expect(LlmService.extractToolCalls(input), isEmpty);
    });

    test('edit_file missing new_string is rejected', () {
      const input = r'''
```tool_call
{"id":"call_edit","name":"edit_file","arguments":{"path":"/tmp/a.txt","old_string":"foo"}}
```
''';
      expect(LlmService.extractToolCalls(input), isEmpty);
    });

    test('edit_file with old_string == new_string is rejected (no-op edit)',
        () {
      const input = r'''
```tool_call
{"id":"call_edit","name":"edit_file","arguments":{"path":"/tmp/a.txt","old_string":"same","new_string":"same"}}
```
''';
      expect(LlmService.extractToolCalls(input), isEmpty);
    });

    test('edit_file new_string may be empty (a deletion edit)', () {
      const input = r'''
```tool_call
{"id":"call_edit","name":"edit_file","arguments":{"path":"/tmp/a.txt","old_string":"remove-me","new_string":""}}
```
''';
      final calls = LlmService.extractToolCalls(input);
      expect(calls.single.isEditFile, isTrue);
      expect(calls.single.newString, equals(''));
    });

    test('edit_file with whitespace-only old_string is rejected', () {
      const input = r'''
```tool_call
{"id":"call_edit","name":"edit_file","arguments":{"path":"/tmp/a.txt","old_string":"   ","new_string":"x"}}
```
''';
      expect(LlmService.extractToolCalls(input), isEmpty);
    });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/services/llm_service_test.dart`
Expected: FAIL — `The getter 'isEditFile' isn't defined for the type 'ToolCall'` (and similarly for `oldString`/`newString`/`replaceAll`).

- [ ] **Step 3: Add the getters to `ToolCall`**

In `lib/services/llm_service.dart`, add right after the `isWriteFile` getter (currently `llm_service.dart:69-70`):

```dart
  bool get isWriteFile =>
      name == 'write_file' || name == 'file_write' || name == 'fs.write';

  bool get isEditFile =>
      name == 'edit_file' || name == 'file_edit' || name == 'fs.edit';
```

Add right after the `content` getter (currently `llm_service.dart:89-92`, just before the `isAskUserQuestion` getter):

```dart
  String? get content {
    final value = arguments['content'] ?? arguments['text'];
    return value is String ? value : null;
  }

  /// `old_string` for an `edit_file` call. Non-null only when the
  /// argument is a String that is non-empty AFTER trimming — a
  /// whitespace-only search target is almost certainly a mistake and
  /// would match too broadly to be useful. The RETURNED value is the
  /// raw (untrimmed) string, though: leading/trailing whitespace can be
  /// exactly what makes a match unique.
  String? get oldString {
    final value = arguments['old_string'];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  /// `new_string` for an `edit_file` call. Unlike [oldString], an empty
  /// string IS a valid replacement (it means "delete old_string") — so
  /// this only checks that the argument is present and is a String.
  String? get newString {
    final value = arguments['new_string'];
    return value is String ? value : null;
  }

  /// `replace_all` for an `edit_file` call — defaults to false (require
  /// an unambiguous single match) when omitted or not a bool.
  bool get replaceAll => arguments['replace_all'] == true;
```

- [ ] **Step 4: Wire `_isSupportedToolCall` and `_dedupeToolCalls`**

In `_isSupportedToolCall` (`llm_service.dart:702-714`), add a branch right after the `isWriteFile` check:

```dart
  static bool _isSupportedToolCall(ToolCall call) {
    if (call.isShell) return call.command != null;
    if (call.isUseSkill) return call.skillId != null;
    if (call.isWebSearch) return call.query != null;
    if (call.isWriteFile) return call.path != null && call.content != null;
    if (call.isEditFile) {
      return call.path != null &&
          call.oldString != null &&
          call.newString != null &&
          call.oldString != call.newString;
    }
    if (call.isAskUserQuestion) {
```

In `_dedupeToolCalls`'s `switch` (`llm_service.dart:780-803`), add a case right after the `write_file` case:

```dart
        'write_file' ||
        'file_write' ||
        'fs.write' => '${call.name}\n${call.path}\n${call.content}',
        'edit_file' ||
        'file_edit' ||
        'fs.edit' =>
          '${call.name}\n${call.path}\n${call.oldString}\n'
          '${call.newString}\n${call.replaceAll}',
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/services/llm_service_test.dart`
Expected: PASS — all tests green, including the 7 new `edit_file` tests.

- [ ] **Step 6: Commit**

```bash
git add lib/services/llm_service.dart test/services/llm_service_test.dart
git commit -m "$(cat <<'EOF'
Add edit_file tool-call parsing to LlmService

New isEditFile/oldString/newString/replaceAll getters on ToolCall,
mirroring write_file's protocol shape. old_string must be non-empty
after trimming; old_string == new_string is rejected as a no-op edit;
new_string may be empty (a deletion).
EOF
)"
```

---

### Task 5: `<file_edit_tool>` system-prompt block

**Files:**
- Modify: `lib/services/llm_service_prompts.dart`
- Test: `test/services/llm_service_test.dart`

**Interfaces:**
- Consumes: `LlmService.systemPromptFor({..., bool fileWriteEnabled})` (already exists, `llm_service.dart:555-579`).
- Produces: `_buildFileEditBlock() → String` (file-private top-level function in `llm_service_prompts.dart`).

- [ ] **Step 1: Write the failing tests**

Add to `test/services/llm_service_test.dart`, right after the existing `'toggling fileWriteEnabled invalidates the cache once'` test:

```dart
    test('fileWriteEnabled=false omits <file_edit_tool> and the tool', () {
      final prompt = LlmService.systemPromptFor(
        enabledSkillIds: <String>{},
        fileWriteEnabled: false,
      );
      expect(prompt.contains('<file_edit_tool>'), isFalse);
      expect(prompt.contains('"name":"edit_file"'), isFalse);
    });

    test('fileWriteEnabled=true injects <file_edit_tool> with tool_call', () {
      final prompt = LlmService.systemPromptFor(
        enabledSkillIds: <String>{},
        fileWriteEnabled: true,
      );
      expect(prompt.contains('<file_edit_tool>'), isTrue);
      expect(prompt.contains('"name":"edit_file"'), isTrue);
      // The critical "must have actually seen this text" rule is the
      // single most important behavioural constraint — pin it so a
      // future prompt rewrite can't silently drop it.
      expect(prompt.contains('old_string'), isTrue);
      expect(prompt.contains('ambiguous_match'), isTrue);
    });

    test('<file_write_tool> turn-shape rule also names edit_file', () {
      // The two file tools must be mutually exclusive within one turn —
      // regression guard for the turn-shape rule text in
      // _buildFileWriteBlock.
      final prompt = LlmService.systemPromptFor(
        enabledSkillIds: <String>{},
        fileWriteEnabled: true,
      );
      final writeBlockStart = prompt.indexOf('<file_write_tool>');
      final writeBlockEnd = prompt.indexOf('</file_write_tool>');
      final writeBlock =
          prompt.substring(writeBlockStart, writeBlockEnd);
      expect(writeBlock.contains('edit_file'), isTrue);
    });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/services/llm_service_test.dart`
Expected: FAIL — the new assertions on `<file_edit_tool>` presence fail (block doesn't exist yet); the `<file_write_tool>` mutual-exclusion test also fails until Step 4.

- [ ] **Step 3: Implement `_buildFileEditBlock` and wire it into `_buildSystemPrompt`**

In `lib/services/llm_service_prompts.dart`, add a new function right after `_buildFileWriteBlock` (which currently ends at line 194):

```dart
/// Returns the `<file_edit_tool>` block for the system prompt, or an
/// empty string when the master switch is off.  Gated by the SAME
/// `fileWriteEnabled` toggle as `<file_write_tool>` — both are disk
/// writes and share one Settings switch (see `_buildFileWriteSection`
/// in `settings_sheet_agent.dart`).
///
/// Unlike `write_file`, this tool does NOT take the new file body — it
/// takes an `old_string`/`new_string` pair and ssterm locates + replaces
/// it locally, so the model never has to retransmit the unchanged parts
/// of a file for a small change.
String _buildFileEditBlock() {
  return '''
<file_edit_tool>
You have a file-edit tool for making a targeted, in-place change to an EXISTING file — a precise search/replace, not a full rewrite. To propose an edit, emit one structured tool call and STOP:

```tool_call
{"id":"call_<short_unique_id>","name":"edit_file","arguments":{"path":"<absolute-path>","old_string":"<exact text currently in the file>","new_string":"<replacement text>","replace_all":false}}
```

Then STOP — the user is shown a chat card with a line-level diff and MUST click Apply before the bytes hit disk. The outcome arrives as a user-role message in your NEXT turn, in one of these shapes:

[File edited]                     [File edit rejected by user]      [File edit failed]
path: …                           path: …                           path: …
edits: <count>                    reason: <free-form>                reason: no_match | ambiguous_match
bytes: …                                                             message: …
mtime: <iso8601>                                                     <recovery hint>

CRITICAL — `old_string` MUST be text you have ACTUALLY SEEN in this conversation (via `cat`, `sed -n`, `grep -n`, or an earlier tool result). Never guess or reconstruct it from memory/training data — an inexact match fails with `no_match`, and a match that occurs more than once (when you didn't set `replace_all`) fails with `ambiguous_match`. Include enough surrounding context in `old_string` to make it unique, or set `"replace_all": true` when you deliberately want every occurrence replaced.

MANDATORY — use `edit_file` for:
- A small, precisely-located change to an existing file (a few lines, a config value, a function body) where you already know the exact current text.
- ANY time you would otherwise reach for `sed -i`, `perl -pi -e`, or similar in-place-edit shell tricks — those are fragile with escaping and give the user no preview.

When NOT to use it (use `write_file` instead):
- Creating a new file.
- A rewrite that touches most of the file, or you don't have the exact current text to anchor on.

Hard rules:
- Path resolution: same rules as `write_file` — absolute paths, `~/…`, or a path relative to the session's PWD (see `<session_context>` if present).
- ONE `edit_file` proposal per turn.
- An `edit_file` tool call turn MUST NOT also contain a shell `tool_call`, `write_file`, [TASK_COMPLETE], [ASK_USER], `ask_user_question`, `use_skill`, or `web_search` — the agent loop intercepts the edit BEFORE running anything, so combining silently drops later actions.
- After a `[File edit rejected by user]` envelope, DO NOT re-emit the same edit for the same path.
- After a `[File edit failed]` envelope with `reason: no_match`, re-read the file to confirm the exact current text before retrying — do NOT resend the same `old_string` unchanged.
- After `reason: ambiguous_match`, either widen `old_string` with more context or add `"replace_all": true`.

Example INVESTIGATE-then-EDIT turn:
  I'll bump the timeout from 30 to 60 seconds.
  ```tool_call
  {"id":"call_bump_timeout","name":"edit_file","arguments":{"path":"/etc/myapp/config.yaml","old_string":"timeout_seconds: 30","new_string":"timeout_seconds: 60","replace_all":false}}
  ```
</file_edit_tool>''';
}
```

Update `_buildSystemPrompt` (`llm_service_prompts.dart:13-25`) so `<file_edit_tool>` appears alongside `<file_write_tool>`:

```dart
String _buildSystemPrompt({
  Set<String>? enabledSkillIds,
  bool webSearchEnabled = false,
  bool fileWriteEnabled = false,
}) {
  final parts = <String>[_systemPromptBase, _buildAskUserQuestionBlock()];
  final enabled = SkillService.filterEnabled(enabledSkillIds);
  if (enabled.isNotEmpty) parts.add(_buildSkillsBlock());
  if (webSearchEnabled) parts.add(_buildWebSearchBlock());
  if (fileWriteEnabled) {
    parts.add(_buildFileWriteBlock());
    parts.add(_buildFileEditBlock());
  }
  parts.add(_buildHostBlock());
  return parts.join('\n\n');
}
```

- [ ] **Step 4: Add `edit_file` to `<file_write_tool>`'s turn-shape rule**

In `_buildFileWriteBlock` (`llm_service_prompts.dart:142-194`), update the turn-shape rule line (currently at `llm_service_prompts.dart:178`):

Find:
```
- A `write_file` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], [ASK_USER], `ask_user_question`, `use_skill`, or `web_search` — the agent loop intercepts the write BEFORE running anything, so combining silently drops later actions.
```

Replace with:
```
- A `write_file` tool call turn MUST NOT also contain a shell `tool_call`, `edit_file`, [TASK_COMPLETE], [ASK_USER], `ask_user_question`, `use_skill`, or `web_search` — the agent loop intercepts the write BEFORE running anything, so combining silently drops later actions.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/services/llm_service_test.dart`
Expected: PASS — all tests green, including the 3 new prompt tests.

- [ ] **Step 6: Commit**

```bash
git add lib/services/llm_service_prompts.dart test/services/llm_service_test.dart
git commit -m "$(cat <<'EOF'
Add the <file_edit_tool> system-prompt block

Documents edit_file's schema, the no_match/ambiguous_match recovery
paths, and when to prefer it over write_file/sed. Gated by the same
fileWriteEnabled toggle as write_file. Cross-references edit_file in
write_file's own turn-shape rule so the two stay mutually exclusive.
EOF
)"
```

---

### Task 6: Wire `edit_file` into the agent panel

This task connects everything built in Tasks 1-5 into the running app: a data model, a diff card widget, agent-loop interception, and the dispatch/callback wiring that makes the card clickable. These pieces are only meaningfully reviewable together (a diff card with nothing to render, or a proposal type nothing constructs, isn't independently useful) — see the design spec's "不在本次范围内" section for why no new automated tests are added here (this project has none for `ai_assistant_panel_loop.dart` or any chat-card widget, and this feature follows that existing pattern). Verification is `flutter analyze` + `flutter test` (full-suite regression) + a manual run-through.

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Create: `lib/widgets/ai_assistant_panel_edit_card.dart`
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Modify: `lib/views/settings/settings_sheet_agent.dart`

**Interfaces:**
- Consumes: `computeLineDiff`/`DiffLine`/`DiffLineKind` (Task 1); `FileSystemAdapter.readContent` (Task 2); `FileEditService`/`EditMatchException`/`EditMatchErrorKind`/`EditMatchResult` (Task 3); `ToolCall.isEditFile`/`oldString`/`newString`/`replaceAll` (Task 4).
- Produces: `_EditProposalOutcome`, `_EditProposalState`, `_EditProposal`, `_ChatMessage.editProposal(...)`, `_EditProposalCard`, `_AiAssistantOverlayState._proposeFileEdit(...)`, `_AiAssistantOverlayState._decideEditProposal(...)`.

- [ ] **Step 1: Add the data model to `ai_assistant_panel_models.dart`**

In `lib/widgets/ai_assistant_panel_models.dart`, add a new section right after the `_WriteProposal` class closing brace (currently ending at line 231, right before the `// ── Command proposal ...` comment block):

```dart
// ── File-edit proposal (Apply/Reject card state machine) ──────────────────

/// Disposition the agent loop should take after `_proposeFileEdit`
/// processes an `edit_file` tool call.  Mirrors [_WriteProposalOutcome]
/// one-for-one but kept as its own enum so the two proposal kinds never
/// get mixed up at a call site.
enum _EditProposalOutcome {
  /// A failure / disabled / no-match / ambiguous-match envelope is
  /// already in conversation history.  Loop should keep iterating so
  /// the model can react.
  injectedAndContinue,

  /// Match succeeded; a diff card is displayed; loop should pause.
  /// Resume happens on Apply / Reject via `_decideEditProposal`.
  waitingForUser,
}

/// Lifecycle states for an [_EditProposal].  Mirrors
/// [_WriteProposalState] one-for-one.
enum _EditProposalState {
  pending,
  applying,
  applied,
  rejected,
  failed,
}

/// Per-proposal record for a pending `edit_file` tool call.  Unlike
/// [_WriteProposal] (which carries the full new file body), this holds
/// the matched `old_string`/`new_string` PLUS both full-text snapshots
/// so the chat card can render a line-level diff via
/// `computeLineDiff(currentContent, newContent)`.
class _EditProposal {
  /// Path as emitted by the model — preserved verbatim for display.
  final String requestedPath;

  /// Adapter-resolved absolute path.  What `commit` will write to.
  final String resolvedPath;

  final String oldString;
  final String newString;

  /// Full file content BEFORE the edit — read via
  /// `FileSystemAdapter.readContent` at proposal time.
  final String currentContent;

  /// Full file content AFTER applying the edit — computed by
  /// `FileEditService.applyEdit` at proposal time (i.e. BEFORE Apply is
  /// clicked), so the diff card can render immediately.
  final String newContent;

  /// How many occurrences of [oldString] were replaced — 1 for a
  /// non-`replace_all` edit, N for `replace_all`.
  final int matchCount;

  /// mtime captured at proposal time — passed to `commit` as the
  /// concurrency token, same as [_WriteProposal.preview]'s mtime.
  final DateTime? mtime;

  /// Generation counter snapshot — same staleness convention as
  /// [_WriteProposal.agentGeneration].
  final int agentGeneration;

  _EditProposalState state = _EditProposalState.pending;

  /// Free-form short message surfaced in the card after a terminal
  /// state (exception message or reject reason).
  String? outcomeMessage;

  /// Set on successful commit.
  FileWriteResult? result;

  _EditProposal({
    required this.requestedPath,
    required this.resolvedPath,
    required this.oldString,
    required this.newString,
    required this.currentContent,
    required this.newContent,
    required this.matchCount,
    required this.mtime,
    required this.agentGeneration,
  });
}
```

In the same file, add a field to `_ChatMessage` right after `_WriteProposal? writeProposal;` (currently line 75):

```dart
  _WriteProposal? writeProposal;

  /// For "file edit proposal" messages: the pending edit_file call the
  /// user must Apply or Reject before the agent loop resumes.  Same
  /// nullable / hot-reload rationale as [writeProposal].  Null for
  /// every other message kind.
  _EditProposal? editProposal;
```

Add `this.editProposal,` to the `_ChatMessage._` private constructor's parameter list (currently lines 90-102, right after `this.writeProposal,`):

```dart
  _ChatMessage._({
    required this.text,
    this.reasoning,
    required this.isUser,
    this.isSystem = false,
    this.isNotice = false,
    this.error,
    this.commandRun,
    this.commandExitCode,
    this.writeProposal,
    this.editProposal,
    this.dangerProposal,
    this.questionProposal,
  });
```

Add a factory right after `_ChatMessage.writeProposal` (currently lines 143-144):

```dart
  factory _ChatMessage.writeProposal(_WriteProposal proposal) =>
      _ChatMessage._(text: '', isUser: false, writeProposal: proposal);

  /// "File edit proposal" card.  Rendered as a distinct Apply/Reject
  /// card with a line-level diff by `_buildAgentMessage`; the contained
  /// [_EditProposal] holds the mutable state machine driving the card.
  factory _ChatMessage.editProposal(_EditProposal proposal) =>
      _ChatMessage._(text: '', isUser: false, editProposal: proposal);
```

- [ ] **Step 2: Add imports and the new part to `ai_assistant_panel.dart`**

In `lib/widgets/ai_assistant_panel.dart`, add two imports right after `import '../services/file_write_service.dart';` (currently line 15):

```dart
import '../services/file_write_service.dart';
import '../services/file_edit_service.dart';
import '../utils/line_diff.dart';
```

Add a new `part` directive right after `part 'ai_assistant_panel_question_card.dart';` (currently line 33, before `part 'ai_assistant_panel_tooling.dart';`):

```dart
part 'ai_assistant_panel_question_card.dart';
part 'ai_assistant_panel_edit_card.dart';
part 'ai_assistant_panel_tooling.dart';
```

- [ ] **Step 3: Create the diff card widget**

Create `lib/widgets/ai_assistant_panel_edit_card.dart`:

```dart
part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _EditProposalCard — chat-card UI for a pending [_EditProposal].
//
// Same Apply/Reject shell as `_WriteProposalCard` (ai_assistant_panel_
// write_card.dart), but the body renders a line-level diff (via
// `computeLineDiff`) instead of a flat content preview, since an edit
// is a targeted change rather than a full-file replacement.
// ───────────────────────────────────────────────────────────────────────────

/// Number of unchanged context lines kept around each change when a run
/// of `equal` lines is long enough to fold.
const _kDiffContextLines = 3;

/// A run of `equal` lines shorter than this is never folded — folding
/// it would save less vertical space than the "N lines unchanged" row
/// itself costs.
const _kDiffFoldThreshold = _kDiffContextLines * 2 + 2;

/// One item in the flattened, fold-aware render list for the diff body.
sealed class _DiffDisplayItem {}

class _DiffLineItem extends _DiffDisplayItem {
  final DiffLine line;
  _DiffLineItem(this.line);
}

class _DiffFoldItem extends _DiffDisplayItem {
  final List<DiffLine> hidden;
  _DiffFoldItem(this.hidden);
}

/// Collapses long runs of unchanged lines in [lines] into
/// [_DiffFoldItem]s, keeping [_kDiffContextLines] lines of context
/// immediately before and after every changed region.  Pure function —
/// no widget state — so it's cheap to recompute on every build.
List<_DiffDisplayItem> _buildDiffDisplayItems(List<DiffLine> lines) {
  final out = <_DiffDisplayItem>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind != DiffLineKind.equal) {
      out.add(_DiffLineItem(lines[i]));
      i++;
      continue;
    }
    var j = i;
    while (j < lines.length && lines[j].kind == DiffLineKind.equal) {
      j++;
    }
    final runLength = j - i;
    if (runLength < _kDiffFoldThreshold) {
      for (var k = i; k < j; k++) {
        out.add(_DiffLineItem(lines[k]));
      }
    } else {
      final headEnd = i + _kDiffContextLines;
      final tailStart = j - _kDiffContextLines;
      final atStart = i == 0;
      final atEnd = j == lines.length;
      if (!atStart) {
        for (var k = i; k < headEnd; k++) {
          out.add(_DiffLineItem(lines[k]));
        }
      }
      final foldStart = atStart ? i : headEnd;
      final foldEnd = atEnd ? j : tailStart;
      if (foldEnd > foldStart) {
        out.add(_DiffFoldItem(lines.sublist(foldStart, foldEnd)));
      }
      if (!atEnd) {
        for (var k = tailStart; k < j; k++) {
          out.add(_DiffLineItem(lines[k]));
        }
      }
    }
    i = j;
  }
  return out;
}

class _EditProposalCard extends StatefulWidget {
  const _EditProposalCard({
    required this.proposal,
    required this.onApply,
    required this.onReject,
  });

  final _EditProposal proposal;
  final VoidCallback onApply;
  final void Function({String? reason}) onReject;

  @override
  State<_EditProposalCard> createState() => _EditProposalCardState();
}

class _EditProposalCardState extends State<_EditProposalCard> {
  bool _rejectFormOpen = false;
  final _reasonController = TextEditingController();
  final Set<int> _expandedFolds = {};

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.7);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    final accent = switch (p.state) {
      _EditProposalState.pending => const Color(0xFFE5C07B),
      _EditProposalState.applying => const Color(0xFF61AFEF),
      _EditProposalState.applied => const Color(0xFF98C379),
      _EditProposalState.rejected => dim,
      _EditProposalState.failed => const Color(0xFFFF6E67),
    };

    final diffLines = computeLineDiff(p.currentContent, p.newContent);
    final displayItems = _buildDiffDisplayItems(diffLines);

    return Container(
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.5), width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildStateBadge(p, accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.resolvedPath,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontFamily: 'JetBrainsMono',
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (p.outcomeMessage != null) ...[
            Text(
              p.outcomeMessage!,
              style: TextStyle(color: accent, fontSize: 12),
            ),
            const SizedBox(height: 6),
          ],
          Container(
            constraints: const BoxConstraints(maxHeight: 360),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var idx = 0; idx < displayItems.length; idx++)
                    _buildDisplayItem(displayItems[idx], idx, fg, dim),
                ],
              ),
            ),
          ),
          if (p.state == _EditProposalState.pending ||
              p.state == _EditProposalState.applying) ...[
            const SizedBox(height: 10),
            if (_rejectFormOpen) ...[
              TextField(
                controller: _reasonController,
                style: TextStyle(color: fg, fontSize: 12),
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'Why? (optional, sent to the model)',
                  hintStyle: TextStyle(
                      color: dim.withValues(alpha: 0.6), fontSize: 12),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: dim.withValues(alpha: 0.3)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: p.state == _EditProposalState.applying
                      ? null
                      : () {
                          if (_rejectFormOpen) {
                            widget.onReject(reason: _reasonController.text);
                          } else {
                            setState(() => _rejectFormOpen = true);
                          }
                        },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6E67),
                  ),
                  child: Text(_rejectFormOpen ? 'Send rejection' : 'Reject'),
                ),
                const SizedBox(width: 8),
                if (p.state == _EditProposalState.applying)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  ElevatedButton(
                    onPressed: widget.onApply,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF98C379),
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Apply'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStateBadge(_EditProposal p, Color accent) {
    final label = switch (p.state) {
      _EditProposalState.pending =>
        p.matchCount > 1 ? 'EDIT ×${p.matchCount}' : 'EDIT',
      _EditProposalState.applying => 'EDITING…',
      _EditProposalState.applied => 'APPLIED',
      _EditProposalState.rejected => 'REJECTED',
      _EditProposalState.failed => 'FAILED',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildDisplayItem(
    _DiffDisplayItem item,
    int index,
    Color fg,
    Color dim,
  ) {
    if (item is _DiffFoldItem) {
      final expanded = _expandedFolds.contains(index);
      if (expanded) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in item.hidden) _buildDiffLine(line, fg, dim),
          ],
        );
      }
      return InkWell(
        onTap: () => setState(() => _expandedFolds.add(index)),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: Text(
            '⋯ ${item.hidden.length} unchanged line'
            '${item.hidden.length == 1 ? '' : 's'} — click to expand ⋯',
            style: TextStyle(
              color: dim,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }
    return _buildDiffLine((item as _DiffLineItem).line, fg, dim);
  }

  Widget _buildDiffLine(DiffLine line, Color fg, Color dim) {
    final (bg, prefix, textColor) = switch (line.kind) {
      DiffLineKind.removed => (
          const Color(0x33FF6E67),
          '-',
          const Color(0xFFFF8A85),
        ),
      DiffLineKind.added => (
          const Color(0x3398C379),
          '+',
          const Color(0xFFA8D6A0),
        ),
      DiffLineKind.equal => (Colors.transparent, ' ', dim),
    };
    final lineNo =
        line.oldLineNo?.toString() ?? line.newLineNo?.toString() ?? '';
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${lineNo.padLeft(5)}  ',
              style: TextStyle(
                color: dim.withValues(alpha: 0.6),
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
              ),
            ),
            TextSpan(
              text: '$prefix ${line.text}',
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Add `_proposeFileEdit`/`_decideEditProposal` to `ai_assistant_panel_tooling.dart`**

In `lib/widgets/ai_assistant_panel_tooling.dart`, add two new methods to the `_AiAgentToolingExt` extension, right after `_decideWriteProposal` (currently ending at line 458, before the `_decideDangerProposal` doc comment):

```dart
  Future<_EditProposalOutcome> _proposeFileEdit({
    required int gen,
    required int iter,
    required String path,
    required String oldString,
    required String newString,
    required bool replaceAll,
    required bool enabled,
    int? turnId,
  }) async {
    final tp = turnId == null ? '' : 't=$turnId ';
    if (!enabled) {
      _logAgent(
        '${tp}iter=$iter file_edit_skip reason=disabled path=${_logQuote(path)}',
      );
      _conversationHistory.add({
        'role': 'user',
        'content':
            '[File edit failed]\n'
            'path: $path\n'
            'reason: disabled\n'
            'message: File write tool is disabled in Settings.\n\n'
            'Tell the user to open Settings → Agent → File write to enable the tool. Proceed without edit_file. Do NOT retry the same edit_file tool call.',
      });
      return _EditProposalOutcome.injectedAndContinue;
    }
    final adapter = widget.fileSystemAdapter;
    if (adapter == null || !adapter.isAvailable) {
      _logAgent(
        '${tp}iter=$iter file_edit_skip reason=no_adapter path=${_logQuote(path)}',
      );
      _conversationHistory.add({
        'role': 'user',
        'content': FileWriteService.formatErrorForLlm(
          path,
          const FileWriteException(
            FileWriteErrorKind.notSupported,
            'No filesystem adapter is available for this tab (likely a non-terminal tab or an SSH session that hasn\'t finished handshaking yet).',
          ),
        ),
      });
      return _EditProposalOutcome.injectedAndContinue;
    }

    setState(() => _agentLoopStatus = 'Reading: $path (${adapter.label})');
    _scrollToBottom();

    FileWritePreview preview;
    String current;
    try {
      preview = await adapter.preview(path);
      current = await adapter.readContent(path);
    } on FileWriteException catch (e) {
      if (!mounted || gen != _generation) {
        return _EditProposalOutcome.injectedAndContinue;
      }
      _logAgent(
        '${tp}iter=$iter file_edit_read_err kind=${e.kind.name} path=${_logQuote(path)}',
      );
      _conversationHistory.add({
        'role': 'user',
        'content': FileWriteService.formatErrorForLlm(path, e),
      });
      return _EditProposalOutcome.injectedAndContinue;
    } catch (e) {
      if (!mounted || gen != _generation) {
        return _EditProposalOutcome.injectedAndContinue;
      }
      _logAgent(
        '${tp}iter=$iter file_edit_read_crash type=${e.runtimeType} path=${_logQuote(path)} msg=${_logQuote('$e')}',
      );
      _conversationHistory.add({
        'role': 'user',
        'content': FileWriteService.formatErrorForLlm(
          path,
          FileWriteException(FileWriteErrorKind.io, '$e'),
        ),
      });
      return _EditProposalOutcome.injectedAndContinue;
    }

    final EditMatchResult matchResult;
    try {
      matchResult = FileEditService.applyEdit(
        current: current,
        oldString: oldString,
        newString: newString,
        replaceAll: replaceAll,
      );
    } on EditMatchException catch (e) {
      if (!mounted || gen != _generation) {
        return _EditProposalOutcome.injectedAndContinue;
      }
      final envelope = e.kind == EditMatchErrorKind.noMatch
          ? FileEditService.formatNoMatchForLlm(path, oldString)
          : FileEditService.formatAmbiguousForLlm(
              path, oldString, e.matchCount);
      _logAgent(
        '${tp}iter=$iter file_edit_match_err kind=${e.kind.name} '
        'count=${e.matchCount} path=${_logQuote(path)}',
      );
      _conversationHistory.add({'role': 'user', 'content': envelope});
      return _EditProposalOutcome.injectedAndContinue;
    }

    final proposal = _EditProposal(
      requestedPath: path,
      resolvedPath: preview.resolvedPath,
      oldString: oldString,
      newString: newString,
      currentContent: current,
      newContent: matchResult.newContent,
      matchCount: matchResult.matchCount,
      mtime: preview.mtime,
      agentGeneration: gen,
    );
    setState(() {
      _messages.add(_ChatMessage.editProposal(proposal));
      _agentLoopStatus = 'Awaiting Apply for edit to ${preview.resolvedPath}';
    });
    _scrollToBottom();
    _logAgent(
      '${tp}iter=$iter file_edit_proposed matches=${matchResult.matchCount} '
      'path=${_logQuote(preview.resolvedPath)}',
    );
    return _EditProposalOutcome.waitingForUser;
  }

  Future<void> _decideEditProposal(
    _EditProposal proposal, {
    required bool apply,
    String? reason,
  }) async {
    if (proposal.state != _EditProposalState.pending) return;

    if (proposal.agentGeneration != _generation) {
      setState(() {
        proposal.state = _EditProposalState.rejected;
        proposal.outcomeMessage =
            'Cancelled — newer conversation started before decision.';
      });
      return;
    }

    final config = widget.agentConfig;
    if (config == null) {
      setState(() {
        proposal.state = _EditProposalState.failed;
        proposal.outcomeMessage = 'Agent is not configured.';
      });
      return;
    }

    String envelope;
    if (!apply) {
      setState(() {
        proposal.state = _EditProposalState.rejected;
        proposal.outcomeMessage = reason;
      });
      envelope = FileEditService.formatRejectionForLlm(
        proposal.requestedPath,
        reason: reason,
      );
      _logAgent('file_edit_rejected path=${_logQuote(proposal.resolvedPath)}');
    } else {
      final adapter = widget.fileSystemAdapter;
      if (adapter == null || !adapter.isAvailable) {
        setState(() {
          proposal.state = _EditProposalState.failed;
          proposal.outcomeMessage =
              'Filesystem adapter is no longer available (tab may have changed).';
        });
        envelope = FileWriteService.formatErrorForLlm(
          proposal.requestedPath,
          const FileWriteException(
            FileWriteErrorKind.notSupported,
            'Filesystem adapter became unavailable between proposal and apply.',
          ),
        );
      } else {
        setState(() => proposal.state = _EditProposalState.applying);
        try {
          final result = await adapter.commit(
            proposal.requestedPath,
            proposal.newContent,
            expectedMtime: proposal.mtime,
          );
          if (!mounted) return;
          setState(() {
            proposal.state = _EditProposalState.applied;
            proposal.result = result;
          });
          envelope = FileEditService.formatSuccessForLlm(
            proposal.matchCount,
            result,
          );
          _logAgent(
            'file_edit_applied matches=${proposal.matchCount} '
            'path=${_logQuote(result.resolvedPath)}',
          );
        } on FileWriteException catch (e) {
          if (!mounted) return;
          setState(() {
            proposal.state = _EditProposalState.failed;
            proposal.outcomeMessage = e.message;
          });
          envelope = FileWriteService.formatErrorForLlm(
            proposal.requestedPath,
            e,
          );
          _logAgent(
            'file_edit_commit_err kind=${e.kind.name} '
            'path=${_logQuote(proposal.resolvedPath)}',
          );
        } catch (e) {
          if (!mounted) return;
          setState(() {
            proposal.state = _EditProposalState.failed;
            proposal.outcomeMessage = '$e';
          });
          envelope = FileWriteService.formatErrorForLlm(
            proposal.requestedPath,
            FileWriteException(FileWriteErrorKind.io, '$e'),
          );
          _logAgent(
            'file_edit_commit_crash type=${e.runtimeType} '
            'path=${_logQuote(proposal.resolvedPath)}',
          );
        }
      }
    }

    _conversationHistory.add({'role': 'user', 'content': envelope});
    _markAgentBusy(autoExecuteLockTerminal: _autoExecute);
    await _continueAgentLoop(_generation, config);
  }
```

- [ ] **Step 5: Intercept `edit_file` in the agent loop**

In `lib/widgets/ai_assistant_panel_loop.dart`, update the tool-call extraction block (currently `ai_assistant_panel_loop.dart:266-290`):

```dart
      ToolCall? useSkillTool;
      ToolCall? webSearchTool;
      ToolCall? writeFileTool;
      ToolCall? editFileTool;
      ToolCall? askUserQuestionTool;
      for (final call in toolCalls) {
        if (useSkillTool == null && call.isUseSkill && call.skillId != null) {
          useSkillTool = call;
        }
        if (webSearchTool == null && call.isWebSearch && call.query != null) {
          webSearchTool = call;
        }
        if (writeFileTool == null &&
            call.isWriteFile &&
            call.path != null &&
            call.content != null) {
          writeFileTool = call;
        }
        if (editFileTool == null &&
            call.isEditFile &&
            call.path != null &&
            call.oldString != null &&
            call.newString != null &&
            call.oldString != call.newString) {
          editFileTool = call;
        }
        if (askUserQuestionTool == null &&
            call.isAskUserQuestion &&
            call.question != null &&
            call.header != null &&
            call.options.length >= 2) {
          askUserQuestionTool = call;
        }
      }
```

Update the `markerLabel` chain (currently `ai_assistant_panel_loop.dart:301-313`):

```dart
      final markerLabel = taskComplete
          ? 'task_complete'
          : (askUser
                ? 'ask_user'
                : (askUserQuestionTool != null
                      ? 'ask_user_question'
                      : (useSkill != null
                            ? 'use_skill:$useSkill'
                            : (webQuery != null
                                  ? 'web_search'
                                  : (writeFile != null
                                        ? 'write_file'
                                        : (editFileTool != null
                                              ? 'edit_file'
                                              : 'none'))))));
```

Add the interception block right after the "File-write proposal" block closes (currently ending at `ai_assistant_panel_loop.dart:463`, right before the "Ask-user question" section comment):

```dart
      // ── File-edit proposal ─────────────────────────────────────────
      // Same intercept-before-execute, pause-for-Apply pattern as
      // write_file — see that section's comment above for the
      // rationale. Match validation (no_match / ambiguous_match)
      // happens INSIDE `_proposeFileEdit`, before any card is shown, so
      // the user never sees a diff card for an edit that's already
      // known to fail.
      if (editFileTool != null) {
        final pauseOutcome = await _proposeFileEdit(
          gen: gen,
          iter: loopIterations,
          turnId: turnId,
          path: editFileTool.path!,
          oldString: editFileTool.oldString!,
          newString: editFileTool.newString!,
          replaceAll: editFileTool.replaceAll,
          enabled: config.fileWriteEnabled,
        );
        if (!mounted || gen != _generation) return;
        switch (pauseOutcome) {
          case _EditProposalOutcome.injectedAndContinue:
            setState(() => _agentLoopStatus = null);
            continue;
          case _EditProposalOutcome.waitingForUser:
            return;
        }
      }
```

- [ ] **Step 6: Wire the dispatch branch in `ai_assistant_panel_content.dart`**

In `lib/widgets/ai_assistant_panel_content.dart`, add a new constructor parameter right after `this.onWriteProposalDecision,` (currently line 34):

```dart
    this.onWriteProposalDecision,
    this.onEditProposalDecision,
```

Add the corresponding field right after the `onWriteProposalDecision` field declaration (currently lines 86-96):

```dart
  final void Function(
    _WriteProposal proposal, {
    required bool apply,
    String? reason,
  })?
  onWriteProposalDecision;

  /// Handler the [_EditProposalCard] calls when the user clicks Apply
  /// or Reject.  Same pattern as [onWriteProposalDecision] — the panel
  /// stays a pure view, the state machine lives in
  /// [_AiAssistantOverlayState._decideEditProposal].
  final void Function(
    _EditProposal proposal, {
    required bool apply,
    String? reason,
  })?
  onEditProposalDecision;
```

In `_buildAgentMessage` (`ai_assistant_panel_content.dart:569-650`), add a new branch right after the `writeProposal` block closes (currently ending at line 610, before the "Dangerous-command proposal" comment):

```dart
    // File-edit proposal: same Apply/Reject shell as the write-proposal
    // card, but the body renders a line-level diff instead of a flat
    // content preview — see `_EditProposalCard`.
    final editProposal = msg.editProposal;
    if (editProposal != null) {
      final decide = onEditProposalDecision;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 32),
        child: _EditProposalCard(
          proposal: editProposal,
          onApply: decide == null
              ? () {}
              : () => decide(editProposal, apply: true),
          onReject: decide == null
              ? ({String? reason}) {}
              : ({String? reason}) =>
                    decide(editProposal, apply: false, reason: reason),
        ),
      );
    }
```

- [ ] **Step 7: Wire the callback at the `_AiPanelContent` call site**

In `lib/widgets/ai_assistant_panel.dart`, add a line right after `onWriteProposalDecision: _decideWriteProposal,` (currently line 566):

```dart
            onWriteProposalDecision: _decideWriteProposal,
            onEditProposalDecision: _decideEditProposal,
```

- [ ] **Step 8: Update the Settings copy**

In `lib/views/settings/settings_sheet_agent.dart`, update `_buildFileWriteSection` (currently `settings_sheet_agent.dart:313-343`):

```dart
        title: const Text(
          'Enable file write & edit',
          style: TextStyle(color: _kFg, fontSize: 13),
        ),
        subtitle: const Text(
          'Lets the agent propose full-file writes (`write_file`) and '
          'targeted search/replace edits (`edit_file`). Every proposal '
          'shows up as a chat card — a diff preview for edits, a '
          'content preview for writes — and requires you to click '
          'Apply before anything hits disk; auto-execute does NOT '
          'auto-write. Local writes use atomic temp+rename; SSH writes '
          'go through the active SFTP session.',
          style: TextStyle(color: _kFgMuted, fontSize: 11, height: 1.3),
        ),
```

- [ ] **Step 9: Run static analysis**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 10: Run the full test suite (regression check)**

Run: `flutter test`
Expected: PASS — every existing test still green, plus all tests added in Tasks 1-5.

- [ ] **Step 11: Manual end-to-end verification**

Run the app (`flutter run -d macos` or the platform of your choice) with a real provider configured and "Enable file write & edit" on, then walk through:

1. Ask the agent to change one specific, already-known line in a small text file → diff card appears **expanded by default**, shows the changed line highlighted red/green with 3 lines of context, path in the header, "EDIT" badge. Click Apply → file on disk actually changes; a `[File edited]` envelope round-trips (visible via the agent's next reply referencing success).
2. Ask for an edit where the target text doesn't exist in the file → NO card appears; the agent's next message shows it recovering (e.g. re-reading the file) rather than silently failing.
3. Ask for an edit whose `old_string` legitimately repeats 2+ times in the file without asking for "all of them" → NO card appears; the agent's next turn either narrows the match or retries with `replace_all`.
4. Ask for a change that legitimately applies to every occurrence (e.g. "rename every use of X to Y in this file") → card shows "EDIT ×N" badge, diff highlights all N sites.
5. Click Reject with a typed reason on a pending edit card → card turns grey/"REJECTED", the agent's next reply acknowledges it and does not immediately resend the same edit.
6. Toggle "Enable file write & edit" off in Settings → Agent, start a fresh conversation, ask for a small file change → the agent falls back to `sed`/shell instead of proposing `edit_file` (confirms the block disappeared from the system prompt).
7. Try an edit on a file that doesn't exist / a path outside any writable location → `[File edit failed]` envelope with a sensible `reason`, no crash.

- [ ] **Step 12: Commit**

```bash
git add lib/widgets/ai_assistant_panel_models.dart \
  lib/widgets/ai_assistant_panel.dart \
  lib/widgets/ai_assistant_panel_edit_card.dart \
  lib/widgets/ai_assistant_panel_tooling.dart \
  lib/widgets/ai_assistant_panel_loop.dart \
  lib/widgets/ai_assistant_panel_content.dart \
  lib/views/settings/settings_sheet_agent.dart
git commit -m "$(cat <<'EOF'
Wire edit_file into the agent panel end-to-end

Adds the _EditProposal state machine and its line-diff Apply/Reject
card, intercepts edit_file in the agent loop right after write_file
(match validation happens before the card is ever shown), and wires
the dispatch/callback plumbing through the panel. Settings copy now
covers both write_file and edit_file under the one existing toggle.
EOF
)"
```

---

## Post-plan notes

- This plan intentionally does not touch `AgentConfig` — `fileWriteEnabled` already covers both tools per the design spec.
- If a future iteration wants `edit_file` to support multiple edits per turn (Claude Code's `MultiEdit` shape), that is out of scope here and would need its own spec — the current design deliberately keeps one edit per turn, matching `write_file`'s existing "one proposal per turn" rule.
