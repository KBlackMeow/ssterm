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

  /// Wraps [FileWriteService.formatErrorForLlm] for adapter-level
  /// failures (disabled/no-adapter/io/permission/mtime-mismatch/etc.)
  /// that `edit_file` shares with `write_file`'s underlying
  /// [FileSystemAdapter]. Rewrites the shared formatter's
  /// `[File write failed]` header to `[File edit failed]` so the
  /// envelope matches what `<file_edit_tool>` in the system prompt
  /// promises. Also rewrites recovery-hint tool references from
  /// `write_file` to `edit_file` so the model knows to retry with the
  /// right tool after an mtime-conflict or other concurrency issue.
  static String formatAdapterErrorForLlm(String path, FileWriteException e) {
    final base = FileWriteService.formatErrorForLlm(path, e);
    return base
        .replaceFirst('[File write failed]', '[File edit failed]')
        .replaceFirst(
          'issue a NEW write_file tool call',
          'issue a NEW edit_file tool call',
        )
        .replaceFirst('then retry write_file', 'then retry edit_file');
  }

  /// Envelope for a proposed edit_file call when the tool is disabled in
  /// Settings. Kept as its own formatter (rather than an inline literal
  /// at the call site) so this envelope can't drift out of sync with
  /// the other edit_file envelope shapes.
  static String formatDisabledForLlm(String path) {
    return '[File edit failed]\n'
        'path: $path\n'
        'reason: disabled\n'
        'message: File write tool is disabled in Settings.\n\n'
        'Tell the user to open Settings → Agent → File write to enable the tool. Proceed without edit_file. Do NOT retry the same edit_file tool call.';
  }
}
