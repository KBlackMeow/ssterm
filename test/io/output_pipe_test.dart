import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:xterm/xterm.dart';

// Minimal stub: only write() is needed for pipe tests.
class _LogStub implements LogSink {
  final List<List<int>> calls = [];
  @override
  void write(List<int> bytes) => calls.add(List.from(bytes));
  @override
  Future<void> close() async {}
}

void main() {
  group('OutputPipe', () {
    test('buffers incoming chunks and flushes to terminal after 16 ms', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        ctrl.add([72, 101, 108, 108, 111]); // "Hello"

        // Before flush: terminal still empty.
        expect(terminal.buffer.lines[0].getText().trim(), isEmpty);

        fake.elapse(const Duration(milliseconds: 20));

        expect(terminal.buffer.lines[0].getText(), contains('Hello'));

        pipe.dispose();
        ctrl.close();
      });
    });

    test('applies transform before writing to terminal', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        // Transform: replace every byte with 65 ('A').
        final pipe = OutputPipe(
          terminal,
          transform: (bytes) => List.filled(bytes.length, 65),
        );
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        ctrl.add([120, 121, 122]); // "xyz"
        fake.elapse(const Duration(milliseconds: 20));

        expect(terminal.buffer.lines[0].getText(), contains('AAA'));

        pipe.dispose();
        ctrl.close();
      });
    });

    test('writes RAW bytes to LogSink before transform is applied', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final log = _LogStub();
        final pipe = OutputPipe(
          terminal,
          logSink: log,
          transform: (bytes) => [65], // single 'A'
        );
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        ctrl.add([1, 2, 3]);
        fake.elapse(const Duration(milliseconds: 20));

        // Log must have received the original bytes, NOT the transformed output.
        expect(log.calls, hasLength(1));
        expect(log.calls.first, equals(Uint8List.fromList([1, 2, 3])));

        pipe.dispose();
        ctrl.close();
      });
    });

    test('chunks larger than 64 KB are split across multiple flush ticks', () {
      fakeAsync((fake) {
        final terminal = Terminal(maxLines: 20000);
        final written = <int>[];
        final pipe = OutputPipe(
          terminal,
          logSink: _LogStub(),
          transform: (bytes) {
            written.addAll(bytes);
            return bytes;
          },
        );
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        // 128 KB — two flushes required.
        ctrl.add(Uint8List(128 * 1024));

        // First flush: exactly 65536 bytes.
        fake.elapse(const Duration(milliseconds: 20));
        expect(written.length, equals(65536));

        // Second flush: remaining 65536 bytes.
        fake.elapse(const Duration(milliseconds: 20));
        expect(written.length, equals(128 * 1024));

        pipe.dispose();
        ctrl.close();
      });
    });

    test('decodes UTF-8 characters split across flush boundaries', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        // U+4F60 "你" split before the final byte.
        ctrl.add([0xE4, 0xBD]);
        fake.elapse(const Duration(milliseconds: 20));
        expect(terminal.buffer.lines[0].getText().trim(), isEmpty);

        ctrl.add([0xA0]);
        fake.elapse(const Duration(milliseconds: 20));

        expect(terminal.buffer.lines[0].getText(), contains('你'));
        expect(terminal.buffer.lines[0].getText(), isNot(contains('�')));

        pipe.dispose();
        ctrl.close();
      });
    });

    test(
      'pauses streams above high watermark and resumes below low watermark',
      () {
        fakeAsync((fake) {
          final terminal = Terminal();
          var pauseCount = 0;
          var resumeCount = 0;
          final ctrl = StreamController<List<int>>(
            onPause: () => pauseCount++,
            onResume: () => resumeCount++,
          );
          final pipe = OutputPipe(
            terminal,
            maxBytesPerWrite: 8,
            queueHighWatermarkBytes: 10,
            queueLowWatermarkBytes: 4,
          );
          pipe.bind(ctrl.stream);

          ctrl.add(List.filled(12, 65));
          fake.flushMicrotasks();

          expect(pauseCount, equals(1));
          expect(resumeCount, equals(0));

          fake.elapse(const Duration(milliseconds: 20));

          expect(resumeCount, equals(1));
          expect(terminal.buffer.lines[0].getText(), contains('AAAAAAAA'));

          pipe.dispose();
          ctrl.close();
        });
      },
    );

    test(
      'holds initial output until release and accepts bytes after release',
      () {
        fakeAsync((fake) {
          final terminal = Terminal();
          var accepted = 0;
          final pipe = OutputPipe(
            terminal,
            holdOutputUntilRelease: true,
            onBytesAccepted: (count) => accepted += count,
          );
          final ctrl = StreamController<List<int>>();
          pipe.bind(ctrl.stream);

          ctrl.add([72, 101, 108, 108, 111]); // "Hello"
          fake.elapse(const Duration(milliseconds: 40));

          expect(terminal.buffer.lines[0].getText().trim(), isEmpty);
          expect(accepted, equals(0));

          pipe.releaseHeldOutput();
          fake.flushMicrotasks();
          expect(accepted, equals(5));

          fake.elapse(const Duration(milliseconds: 20));

          expect(terminal.buffer.lines[0].getText(), contains('Hello'));

          pipe.dispose();
          ctrl.close();
        });
      },
    );

    test('delays accepting bytes while high-water paused', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final accepted = <int>[];
        final pipe = OutputPipe(
          terminal,
          maxBytesPerWrite: 8,
          queueHighWatermarkBytes: 10,
          queueLowWatermarkBytes: 4,
          onBytesAccepted: accepted.add,
        );
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        ctrl.add(List.filled(12, 65));
        fake.flushMicrotasks();

        expect(accepted, isEmpty);

        fake.elapse(const Duration(milliseconds: 20));

        expect(accepted, equals([12]));

        pipe.dispose();
        ctrl.close();
      });
    });

    test('metrics expose queue and backpressure state', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final pipe = OutputPipe(
          terminal,
          holdOutputUntilRelease: true,
          queueHighWatermarkBytes: 10,
          queueLowWatermarkBytes: 4,
        );
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        ctrl.add(List.filled(12, 65));
        fake.flushMicrotasks();

        expect(pipe.metrics.queuedBytes, 12);
        expect(pipe.metrics.streamsPaused, isTrue);
        expect(pipe.metrics.pendingAcceptedBytes, 12);
        expect(pipe.metrics.holdOutputUntilRelease, isTrue);

        pipe.dispose();
        ctrl.close();
      });
    });

    test('flushSync drains pending output immediately', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        ctrl.add([78, 111, 119]); // "Now"
        fake.flushMicrotasks();

        expect(terminal.buffer.lines[0].getText().trim(), isEmpty);

        pipe.flushSync();

        expect(terminal.buffer.lines[0].getText(), contains('Now'));

        pipe.dispose();
        ctrl.close();
      });
    });

    test('dispose cancels pending flush — no write after dispose', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        ctrl.add([65]); // 'A'
        pipe.dispose(); // cancel before flush fires

        fake.elapse(const Duration(milliseconds: 20));

        // Nothing should have been written.
        expect(terminal.buffer.lines[0].getText().trim(), isEmpty);

        ctrl.close();
      });
    });

    test('bind multiple streams — all chunks reach terminal', () {
      fakeAsync((fake) {
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final a = StreamController<List<int>>();
        final b = StreamController<List<int>>();
        pipe.bind(a.stream);
        pipe.bind(b.stream);

        a.add([65]); // 'A'
        b.add([66]); // 'B'
        fake.elapse(const Duration(milliseconds: 20));

        final text = terminal.buffer.lines[0].getText();
        expect(text, contains('A'));
        expect(text, contains('B'));

        pipe.dispose();
        a.close();
        b.close();
      });
    });
  });
}
