import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/services/rust_terminal_bridge.dart';
import 'package:ssterm/services/rust_terminal_core.dart';
import 'package:xterm/xterm.dart';

String _libraryPath() {
  const base = 'native/terminal_core/target/release';
  if (Platform.isMacOS) return '$base/libssterm_terminal_core.dylib';
  if (Platform.isWindows) return '$base/ssterm_terminal_core.dll';
  return '$base/libssterm_terminal_core.so';
}

void main() {
  test(
    'profiles native terminal output batch sizes',
    () async {
      final payload = utf8.encode(
        List.generate(2000000, (index) => '${index + 1}\r\n').join(),
      );

      for (final batchSize in <int>[
        256 * 1024,
        1024 * 1024,
        2 * 1024 * 1024,
        4 * 1024 * 1024,
        payload.length,
      ]) {
        final terminal = Terminal(maxLines: 5000)..resize(120, 40);
        final core = RustTerminalCore.open(
          columns: 120,
          rows: 40,
          maxScrollbackRows: 4960,
          libraryPath: _libraryPath(),
        );
        final bridge = RustTerminalBridge(core: core, terminal: terminal);
        final accepted = Completer<void>();
        var acceptedBytes = 0;
        final pipe = OutputPipe(
          terminal,
          terminalByteSink: bridge,
          maxBytesPerWrite: batchSize,
          pauseSourceOnBackpressure: false,
          onBytesAccepted: (bytes) {
            acceptedBytes += bytes;
            if (acceptedBytes == payload.length && !accepted.isCompleted) {
              accepted.complete();
            }
          },
        );
        final controller = StreamController<List<int>>();
        pipe.bind(controller.stream);

        final watch = Stopwatch()..start();
        for (var offset = 0; offset < payload.length; offset += 32768) {
          final end = (offset + 32768).clamp(0, payload.length);
          controller.add(Uint8List.sublistView(payload, offset, end));
        }
        await accepted.future;
        while (pipe.metrics.queuedBytes != 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final drained = watch.elapsedMicroseconds;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        watch.stop();

        final visible = <String>[
          for (var row = 0; row < terminal.viewHeight; row++)
            core.rowText(row),
        ].join('\n');
        expect(visible, contains('2000000'));

        // ignore: avoid_print
        print(
          'batch=$batchSize bytes=${payload.length} '
          'drain=${drained / 1000}ms settled=${watch.elapsedMilliseconds}ms',
        );

        pipe.dispose();
        bridge.close();
        core.close();
        await controller.close();
      }
    },
    skip: Platform.environment['SSTERM_RUN_PERF'] == '1'
        ? false
        : 'Set SSTERM_RUN_PERF=1 to run profiling.',
  );
}
