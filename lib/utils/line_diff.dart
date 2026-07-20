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
