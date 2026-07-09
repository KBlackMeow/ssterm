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

    test('captures clean output between OSC 133 ; C and OSC 133 ; D', () async {
      // Real timers: awaitNextCommand uses Timer.periodic which fakeAsync
      // cannot drive across async stream subscriptions in this test.
      final terminal = Terminal();
      final pipe = OutputPipe(terminal);
      final ctrl = StreamController<List<int>>();
      pipe.bind(ctrl.stream);

      // ESC ] 133 ; C BEL  → output start
      const cStart = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x43, 0x07];
      // "hello\n" with an ANSI colour wrapper.
      const colored = [
        0x1B, 0x5B, 0x33, 0x32, 0x6D, // ESC[32m
        0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A, // "hello\n"
        0x1B, 0x5B, 0x30, 0x6D, // ESC[0m
      ];
      // ESC ] 133 ; D ; 7 BEL → output end, exit code 7
      const dEnd = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x44, 0x3B, 0x37, 0x07];

      final pending = pipe.awaitNextCommand(
        timeout: const Duration(seconds: 2),
      );

      ctrl.add([...cStart, ...colored, ...dEnd]);

      // Wait for the 16 ms flush to fire.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = await pending;
      expect(result, isNotNull);
      expect(result!.exitCode, 7);
      expect(result.output, equals('hello'));
      expect(pipe.hasOsc133, isTrue);

      pipe.dispose();
      await ctrl.close();
    });

    test('flags truncation when capture exceeds the 256 KB cap', () async {
      final terminal = Terminal(maxLines: 100000);
      final pipe = OutputPipe(terminal);
      final ctrl = StreamController<List<int>>();
      pipe.bind(ctrl.stream);

      const cStart = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x43, 0x07];
      const dEnd = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x44, 0x3B, 0x30, 0x07];
      // 300 KB of 'A' bytes — exceeds the 256 KB cap.
      final huge = Uint8List(300 * 1024)..fillRange(0, 300 * 1024, 0x41);

      final pending = pipe.awaitNextCommand(
        timeout: const Duration(seconds: 5),
      );

      ctrl.add(cStart);
      // Send the huge body in 32 KB chunks so multiple flushes process it.
      for (var i = 0; i < huge.length; i += 32 * 1024) {
        final end = (i + 32 * 1024 < huge.length) ? i + 32 * 1024 : huge.length;
        ctrl.add(Uint8List.sublistView(huge, i, end));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      ctrl.add(dEnd);

      final result = await pending;
      expect(result, isNotNull);
      expect(result!.exitCode, 0);
      expect(
        result.truncated,
        isTrue,
        reason: 'should flag truncation when shell output exceeds cap',
      );
      // Captured output should be ≤ cap and consist of 'A's only.
      expect(result.output.length, lessThanOrEqualTo(256 * 1024));

      pipe.dispose();
      await ctrl.close();
    });

    test(
      'abandoned capture (timeout) drops the late D — next awaiter sees the right command',
      () async {
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        const cStart = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x43, 0x07];
        const dEnd1 = [
          0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x44, 0x3B, 0x37, 0x07, // exit=7
        ];
        const dEnd0 = [
          0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x44, 0x3B, 0x30, 0x07, // exit=0
        ];
        const body1 = [0x6F, 0x6C, 0x64]; // "old"
        const body2 = [0x6E, 0x65, 0x77]; // "new"

        // Round 1: caller times out FAST.  The shell never finished, so we
        // open the C and stop there before sending D.
        final pending1 = pipe.awaitNextCommand(
          timeout: const Duration(milliseconds: 50),
        );
        ctrl.add(cStart);
        ctrl.add(body1);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // No D yet — let the timeout fire.
        final result1 = await pending1;
        expect(result1, isNull, reason: 'first call should time out');

        // Now the SHELL eventually finishes the abandoned command and emits
        // its D (with the wrong exit code from the agent's perspective).
        ctrl.add(dEnd1);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Round 2: a fresh awaiter for a NEW command.  The bytes for the
        // previous (abandoned) command must NOT bleed into this result.
        final pending2 = pipe.awaitNextCommand(
          timeout: const Duration(seconds: 2),
        );
        ctrl.add(cStart);
        ctrl.add(body2);
        ctrl.add(dEnd0);

        final result2 = await pending2;
        expect(result2, isNotNull);
        expect(
          result2!.exitCode,
          0,
          reason: 'must reflect the NEW command, not the abandoned one',
        );
        expect(
          result2.output,
          equals('new'),
          reason: 'must contain only the new command\'s bytes',
        );

        pipe.dispose();
        await ctrl.close();
      },
    );

    test(
      'startup D without C is silently dropped — first awaiter still gets the real C/D pair',
      () async {
        // Reproduces the misalignment bug: zsh/bash run their `precmd` hook
        // once before the first prompt, so OutputPipe sees a stray
        // `OSC 133;D;0` *before* any real command.  If we emitted a phantom
        // CommandResult for it, every subsequent agent command would receive
        // the *previous* command's D — output and exit codes would all shift
        // by one.
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        const startupD = [
          0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x44, 0x3B, 0x30, 0x07, // exit=0
        ];
        const cStart = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x43, 0x07];
        const body = [0x6F, 0x6B]; // "ok"
        const dEnd = [
          0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x44, 0x3B, 0x35, 0x07, // exit=5
        ];

        // Phase 1: shell starts up, emits the startup D before anyone listens.
        ctrl.add(startupD);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // The pipe should have learned the shell speaks OSC 133, but NOT
        // produced any CommandResult.
        expect(pipe.hasOsc133, isTrue);

        // Phase 2: the first agent command registers its awaiter, then the
        // shell does a real C/body/D round-trip.  The awaiter MUST receive
        // exit=5 (the real command) — not exit=0 (the startup D).
        final pending = pipe.awaitNextCommand(
          timeout: const Duration(seconds: 2),
        );
        ctrl.add([...cStart, ...body, ...dEnd]);

        final result = await pending;
        expect(result, isNotNull);
        expect(
          result!.exitCode,
          5,
          reason: 'must reflect the real command, not the startup D',
        );
        expect(result.output, equals('ok'));

        pipe.dispose();
        await ctrl.close();
      },
    );

    test(
      'OSC 133 capture survives chunk boundaries inside the marker',
      () async {
        final terminal = Terminal();
        final pipe = OutputPipe(terminal);
        final ctrl = StreamController<List<int>>();
        pipe.bind(ctrl.stream);

        const cStart = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B, 0x43, 0x07];
        const body = [0x6F, 0x6B, 0x0A]; // "ok\n"
        const dEnd = [
          0x1B,
          0x5D,
          0x31,
          0x33,
          0x33,
          0x3B,
          0x44,
          0x3B,
          0x30,
          0x07,
        ];

        final pending = pipe.awaitNextCommand(
          timeout: const Duration(seconds: 2),
        );

        // Send the C marker straddling a flush boundary: first chunk has the
        // first 4 bytes, second chunk has the rest plus the body and D.
        ctrl.add(cStart.sublist(0, 4));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ctrl.add([...cStart.sublist(4), ...body, ...dEnd]);

        final result = await pending;
        expect(result, isNotNull);
        expect(result!.exitCode, 0);
        expect(result.output, equals('ok'));

        pipe.dispose();
        await ctrl.close();
      },
    );

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
