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
      expect(result.newContent, equals('keep--keep'));
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

    test('formatAdapterErrorForLlm rewrites the write_file header to '
        'edit_file\'s own', () {
      final out = FileEditService.formatAdapterErrorForLlm(
        '/tmp/x',
        const FileWriteException(FileWriteErrorKind.permission, 'denied'),
      );
      expect(out, contains('[File edit failed]'));
      expect(out, isNot(contains('[File write failed]')));
      // Body content (reason/message/recovery hint) must be preserved —
      // only the header line changes.
      expect(out, contains('reason: permission'));
      expect(out, contains('denied'));
    });
  });
}
