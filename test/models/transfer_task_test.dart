import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/transfer_task.dart';

void main() {
  group('sftpUploadTempPath', () {
    test('places the private upload file beside the destination', () {
      expect(
        sftpUploadTempPath('/srv/files/report.csv', nonce: 'abc'),
        '/srv/files/.ssterm-upload-abc.part',
      );
      expect(
        sftpUploadTempPath('report.csv', nonce: 'abc'),
        '.ssterm-upload-abc.part',
      );
    });

    test('does not reuse the destination name', () {
      final first = sftpUploadTempPath('/srv/files/report.csv');
      final second = sftpUploadTempPath('/srv/files/report.csv');

      expect(first, isNot('/srv/files/report.csv'));
      expect(second, isNot(first));
    });
  });

  group('pumpSftpUpload', () {
    test('pipelines writes up to the configured limit', () async {
      final writes = <({Uint8List data, int offset, Completer<void> done})>[];
      final progress = <int>[];

      final upload = pumpSftpUpload(
        source: Stream.value(<int>[0, 1, 2, 3, 4, 5, 6, 7]),
        chunkSize: 2,
        maxPendingWrites: 3,
        waitUntilRunnable: () async => true,
        write: (data, offset) {
          final done = Completer<void>();
          writes.add((
            data: Uint8List.fromList(data),
            offset: offset,
            done: done,
          ));
          return done.future;
        },
        onProgress: progress.add,
      );

      await pumpEventQueue();
      expect(writes.length, 3);
      expect(writes.map((item) => item.offset), [0, 2, 4]);

      writes[0].done.complete();
      await pumpEventQueue();
      expect(writes.length, 4);
      expect(writes.last.offset, 6);

      for (final item in writes.skip(1)) {
        item.done.complete();
      }
      await upload;
      expect(progress, [2, 4, 6, 8]);
    });

    test(
      'propagates a write failure after draining in-flight writes',
      () async {
        final writes = <Completer<void>>[];

        final upload = pumpSftpUpload(
          source: Stream.value(<int>[0, 1, 2]),
          chunkSize: 1,
          maxPendingWrites: 3,
          waitUntilRunnable: () async => true,
          write: (_, _) {
            final done = Completer<void>();
            writes.add(done);
            return done.future;
          },
          onProgress: (_) {},
        );

        await pumpEventQueue();
        writes[1].completeError(StateError('write failed'));
        writes[0].complete();
        await pumpEventQueue();

        var completed = false;
        upload.whenComplete(() => completed = true).ignore();
        await pumpEventQueue();
        expect(completed, isFalse);

        writes[2].complete();
        await expectLater(upload, throwsStateError);
      },
    );

    test('stops scheduling new writes when cancelled', () async {
      var runnable = true;
      final offsets = <int>[];

      await pumpSftpUpload(
        source: Stream.fromIterable([
          <int>[0, 1],
          <int>[2, 3],
        ]),
        chunkSize: 2,
        maxPendingWrites: 2,
        waitUntilRunnable: () async => runnable,
        write: (_, offset) async {
          offsets.add(offset);
          runnable = false;
        },
        onProgress: (_) {},
      );

      expect(offsets, [0]);
    });
  });

  group('cleanupIncompleteSftpUpload', () {
    test('closes the handle before removing the partial file', () async {
      final operations = <String>[];

      await cleanupIncompleteSftpUpload(
        close: () async => operations.add('close'),
        remove: () async => operations.add('remove'),
      );

      expect(operations, ['close', 'remove']);
    });

    test('still attempts removal when closing the handle fails', () async {
      var removed = false;

      await cleanupIncompleteSftpUpload(
        close: () => Future<void>.error(StateError('connection lost')),
        remove: () async => removed = true,
      );

      expect(removed, isTrue);
    });

    test('does not replace the original outcome when removal fails', () async {
      await expectLater(
        cleanupIncompleteSftpUpload(
          close: () async {},
          remove: () => Future<void>.error(StateError('connection lost')),
        ),
        completes,
      );
    });
  });
}
