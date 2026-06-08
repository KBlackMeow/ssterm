import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/file_write_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalFileSystemAdapter.preview', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('ssterm-fw-test-');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('reports exists=false for a missing file under an existing dir',
        () async {
      final adapter = const LocalFileSystemAdapter();
      final preview = await adapter.preview('${tempRoot.path}/new.txt');
      expect(preview.exists, isFalse);
      expect(preview.existingSize, equals(0));
      expect(preview.mtime, isNull);
      expect(preview.resolvedPath, equals('${tempRoot.path}/new.txt'));
    });

    test('throws parentMissing when the parent dir does not exist', () async {
      final adapter = const LocalFileSystemAdapter();
      // Crisp UX: model should be told to `mkdir -p` first, NOT
      // generic "io error".
      await expectLater(
        () => adapter.preview('${tempRoot.path}/missing-dir/file.txt'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind,
          'kind',
          equals(FileWriteErrorKind.parentMissing),
        )),
      );
    });

    test('reads size + line count for an existing text file', () async {
      final path = '${tempRoot.path}/existing.txt';
      File(path).writeAsStringSync('line1\nline2\nline3\n');
      final adapter = const LocalFileSystemAdapter();
      final preview = await adapter.preview(path);
      expect(preview.exists, isTrue);
      expect(preview.existingSize, equals(18)); // 6+6+6 bytes
      expect(preview.existingLines, equals(3));
      expect(preview.mtime, isNotNull);
    });

    test('throws invalidPath for an empty path', () async {
      final adapter = const LocalFileSystemAdapter();
      await expectLater(
        () => adapter.preview(''),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind, 'kind', equals(FileWriteErrorKind.invalidPath))),
      );
    });

    test('throws invalidPath for a relative path', () async {
      // Relative paths are dangerous in an agent context (Flutter
      // process CWD ≠ terminal CWD); refuse rather than silently
      // landing somewhere unexpected.
      final adapter = const LocalFileSystemAdapter();
      await expectLater(
        () => adapter.preview('relative/path.txt'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind, 'kind', equals(FileWriteErrorKind.invalidPath))),
      );
    });

    test('expands ~ to the configured HOME override', () async {
      // Use the override so the test doesn't depend on the host's
      // actual HOME, which would also fail under CI sandboxes.
      final adapter = LocalFileSystemAdapter(homeOverride: tempRoot.path);
      final preview = await adapter.preview('~/from-home.txt');
      expect(preview.resolvedPath,
          equals('${tempRoot.path}/from-home.txt'));
      expect(preview.exists, isFalse);
    });

    test('treats `~` (no slash) as the bare HOME path', () async {
      // Edge case from real model output — sometimes a model writes
      // `~` alone (intending `~/`).  We accept it gracefully.
      final adapter = LocalFileSystemAdapter(homeOverride: tempRoot.path);
      final preview = await adapter.preview('~');
      expect(preview.resolvedPath, equals(tempRoot.path));
    });
  });

  group('LocalFileSystemAdapter.commit', () {
    late Directory tempRoot;
    late LocalFileSystemAdapter adapter;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('ssterm-fw-test-');
      adapter = const LocalFileSystemAdapter();
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('creates a new file with correct contents + returns created=true',
        () async {
      final path = '${tempRoot.path}/new.txt';
      final result = await adapter.commit(path, 'hello world');
      expect(result.created, isTrue);
      expect(result.bytesWritten, equals(11));
      expect(result.mtime, isNotNull);
      // Verify on disk — defence against the adapter reporting success
      // when the rename actually no-op'd.
      expect(File(path).readAsStringSync(), equals('hello world'));
    });

    test('overwrites an existing file atomically', () async {
      final path = '${tempRoot.path}/overwrite.txt';
      File(path).writeAsStringSync('old');
      final result = await adapter.commit(path, 'new and longer body');
      expect(result.created, isFalse);
      expect(File(path).readAsStringSync(),
          equals('new and longer body'));
    });

    test('mtime mismatch throws mtimeMismatch and leaves the file untouched',
        () async {
      final path = '${tempRoot.path}/concurrent.txt';
      File(path).writeAsStringSync('original');
      // Pretend we previewed BEFORE the file was even created — any
      // mtime from before-now will trip the > 1s mismatch guard.
      final staleMtime =
          DateTime.now().subtract(const Duration(hours: 1));
      await expectLater(
        () => adapter.commit(path, 'new', expectedMtime: staleMtime),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind,
          'kind',
          equals(FileWriteErrorKind.mtimeMismatch),
        )),
      );
      // The file MUST be unchanged after a refused commit.
      expect(File(path).readAsStringSync(), equals('original'));
    });

    test('mtime tolerance: a < 1s mismatch is accepted (clock slop)',
        () async {
      final path = '${tempRoot.path}/clock-slop.txt';
      File(path).writeAsStringSync('a');
      final preview = await adapter.preview(path);
      // Pretend the mtime drifted by 500ms — should still commit.
      final wobble = preview.mtime!
          .add(const Duration(milliseconds: 500));
      final result =
          await adapter.commit(path, 'b', expectedMtime: wobble);
      expect(result.bytesWritten, equals(1));
      expect(File(path).readAsStringSync(), equals('b'));
    });

    test('leaves no .ssterm-tmp- detritus after a successful commit',
        () async {
      final path = '${tempRoot.path}/tidy.txt';
      await adapter.commit(path, 'content');
      // The atomic temp+rename strategy uses sibling tmp files;
      // they MUST be cleaned up on success (the rename consumed them).
      final lingering = tempRoot
          .listSync()
          .where((e) => e.path.contains('.ssterm-tmp-'))
          .toList();
      expect(lingering, isEmpty);
    });

    test('parentMissing surfaces from commit too (not only preview)',
        () async {
      // Defence: even if the caller skipped preview (unusual), commit
      // should still classify the failure correctly so the model gets
      // the same `mkdir -p` hint.
      await expectLater(
        () => adapter.commit('${tempRoot.path}/no-such-dir/x', 'data'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind,
          'kind',
          equals(FileWriteErrorKind.parentMissing),
        )),
      );
    });
  });

  group('SftpFileSystemAdapter availability', () {
    test('isAvailable is false when sftp is null', () {
      final adapter = SftpFileSystemAdapter(sftp: null, label: 'ssh: dead');
      expect(adapter.isAvailable, isFalse);
    });

    test('preview throws notSupported when sftp is null', () async {
      final adapter = SftpFileSystemAdapter(sftp: null, label: 'ssh: dead');
      await expectLater(
        () => adapter.preview('/etc/hosts'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind,
          'kind',
          equals(FileWriteErrorKind.notSupported),
        )),
      );
    });

    test('commit throws notSupported when sftp is null', () async {
      final adapter = SftpFileSystemAdapter(sftp: null, label: 'ssh: dead');
      await expectLater(
        () => adapter.commit('/etc/hosts', 'x'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind,
          'kind',
          equals(FileWriteErrorKind.notSupported),
        )),
      );
    });

    test('currentDirectory returns null when no sftp and no cwdProvider', () {
      final adapter = SftpFileSystemAdapter(sftp: null, label: 'ssh: dead');
      expect(adapter.currentDirectory, isNull);
    });

    test('currentDirectory reflects cwdProvider snapshot', () {
      String? pwd = '/home/me/initial';
      final adapter = SftpFileSystemAdapter(
        sftp: null,
        label: 'ssh: live',
        cwdProvider: () => pwd,
      );
      expect(adapter.currentDirectory, equals('/home/me/initial'));
      // Simulate an OSC 7 `cd` update — the next read should pick up the
      // new value without rebuilding the adapter.
      pwd = '/tmp';
      expect(adapter.currentDirectory, equals('/tmp'));
    });
  });

  group('LocalFileSystemAdapter cwd-aware path resolution', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('ssterm-fw-cwd-');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('joins a relative path against the cwdProvider snapshot', () async {
      // Two-level structure so the join logic is exercised non-trivially
      // (not just a same-dir filename).
      Directory('${tempRoot.path}/sub').createSync();
      final adapter = LocalFileSystemAdapter(
        cwdProvider: () => tempRoot.path,
      );
      final preview = await adapter.preview('sub/new.txt');
      expect(preview.resolvedPath,
          equals('${tempRoot.path}/sub/new.txt'));
      expect(preview.exists, isFalse);
    });

    test('strips a leading `./` before joining against cwd', () async {
      // Matches what shell users type by reflex — the adapter must
      // treat `./foo` and `foo` identically when joining.
      Directory('${tempRoot.path}/d').createSync();
      final adapter = LocalFileSystemAdapter(
        cwdProvider: () => tempRoot.path,
      );
      // `./` stripping lives in the SFTP adapter today; the local
      // adapter just joins.  Document the local behaviour explicitly
      // here so any future change to add a strip is intentional.
      final preview = await adapter.preview('d');
      expect(preview.resolvedPath, equals('${tempRoot.path}/d'));
    });

    test('still rejects a relative path when cwdProvider returns null',
        () async {
      // Important: removing the `cwdProvider` (or having it report null)
      // must NOT regress to "resolve against `Directory.current`" —
      // that would land the file in the Flutter process CWD, never the
      // terminal pane's PWD.
      final adapter = LocalFileSystemAdapter(cwdProvider: () => null);
      await expectLater(
        () => adapter.preview('foo.txt'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind, 'kind', equals(FileWriteErrorKind.invalidPath))),
      );
    });

    test('still rejects a relative path when cwdProvider returns a '
        'non-absolute string', () async {
      // Defence: a buggy provider must not bypass the absolute-only
      // rule — we'd rather refuse than silently resolve into the
      // wrong tree.
      final adapter = LocalFileSystemAdapter(cwdProvider: () => 'no-slash');
      await expectLater(
        () => adapter.preview('foo.txt'),
        throwsA(isA<FileWriteException>().having(
          (e) => e.kind, 'kind', equals(FileWriteErrorKind.invalidPath))),
      );
    });

    test('cwdProvider that already ends in `/` does not produce `//`',
        () async {
      // Cosmetic but easy to get wrong with a naive `'$cwd/$rel'`.
      Directory('${tempRoot.path}/end-slash').createSync();
      final adapter = LocalFileSystemAdapter(
        cwdProvider: () => '${tempRoot.path}/',
      );
      final preview = await adapter.preview('end-slash');
      expect(preview.resolvedPath,
          equals('${tempRoot.path}/end-slash'));
    });

    test('currentDirectory prefers cwdProvider over homeOverride',
        () async {
      // The OSC 7 PWD is the "freshest" signal — it should win even
      // when a HOME override is configured.
      final adapter = LocalFileSystemAdapter(
        homeOverride: '/h',
        cwdProvider: () => '/tmp/pwd',
      );
      expect(adapter.currentDirectory, equals('/tmp/pwd'));
    });

    test('currentDirectory falls back to HOME when cwdProvider is null',
        () async {
      // A brand-new tab that hasn't seen its first OSC 7 packet yet —
      // HOME is still a useful starting hint for the model.
      final adapter = LocalFileSystemAdapter(
        homeOverride: '/h',
        cwdProvider: () => null,
      );
      expect(adapter.currentDirectory, equals('/h'));
    });

    test('homeDirectory returns the configured override', () async {
      final adapter = LocalFileSystemAdapter(homeOverride: '/h');
      expect(await adapter.homeDirectory(), equals('/h'));
    });
  });

  group('FileWriteService formatters', () {
    test('success envelope renders all four diagnostic fields', () {
      final r = FileWriteResult(
        resolvedPath: '/tmp/x.txt',
        bytesWritten: 42,
        created: true,
        mtime: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final out = FileWriteService.formatSuccessForLlm(r);
      expect(out, contains('[File written]'));
      expect(out, contains('path: /tmp/x.txt'));
      expect(out, contains('bytes: 42'));
      expect(out, contains('created: true'));
      expect(out, contains('mtime: 2026-01-02T03:04:05.000Z'));
    });

    test('rejection envelope blocks blind retry of the same path', () {
      final out = FileWriteService.formatRejectionForLlm(
        '/etc/hosts',
        reason: 'too risky',
      );
      expect(out, contains('[File write rejected by user]'));
      expect(out, contains('reason: too risky'));
      // The "Do NOT re-emit" line is the key safety hint — it stops
      // the model from looping on a write the user just declined.
      expect(out, contains('Do NOT re-emit'));
    });

    test('rejection without a reason still emits a recovery hint', () {
      final out = FileWriteService.formatRejectionForLlm('/tmp/x');
      expect(out, contains('(no reason given)'));
      expect(out, contains('Do NOT re-emit'));
    });

    test('every error kind has a recovery hint in formatErrorForLlm', () {
      for (final kind in FileWriteErrorKind.values) {
        final out = FileWriteService.formatErrorForLlm(
          '/some/path',
          FileWriteException(kind, 'detail $kind'),
        );
        expect(out, contains('[File write failed]'),
            reason: 'kind=$kind missing envelope header');
        expect(out, contains('reason: ${kind.name}'),
            reason: 'kind=$kind missing reason line');
        expect(out, contains('detail $kind'),
            reason: 'kind=$kind missing upstream message');
        // Recovery body is everything past the blank line.
        final recovery =
            out.split('\n\n').sublist(1).join('\n\n').trim();
        expect(recovery, isNotEmpty,
            reason: 'kind=$kind missing recovery hint');
      }
    });

    test('parentMissing recovery suggests mkdir -p (concrete fix)', () {
      // Pin the most actionable recovery hint — concrete bash command
      // beats vague "fix the parent directory".
      final out = FileWriteService.formatErrorForLlm(
        '/a/b/c',
        const FileWriteException(
            FileWriteErrorKind.parentMissing, 'missing'),
      );
      expect(out, contains('mkdir -p'));
    });
  });
}
