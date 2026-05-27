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
