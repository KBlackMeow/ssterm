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
