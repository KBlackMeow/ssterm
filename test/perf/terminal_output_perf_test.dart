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
  final runPerf = Platform.environment['SSTERM_RUN_PERF'] == '1';

  test('large output flood drains without pathological delay', () async {
    final terminal = Terminal(maxLines: 400000);
    final accepted = <int>[];
    final pipe = OutputPipe(terminal, onBytesAccepted: accepted.add);
    final ctrl = StreamController<List<int>>();
    pipe.bind(ctrl.stream);

    final payload = utf8.encode(
      List.generate(300000, (i) => '${i + 1}').join('\n'),
    );

    final watch = Stopwatch()..start();
    ctrl.add(payload);
    await Future<void>.delayed(const Duration(seconds: 2));
    watch.stop();

    expect(accepted.fold<int>(0, (sum, value) => sum + value), payload.length);
    expect(terminal.buffer.lines.length, greaterThan(1000));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));

    pipe.dispose();
    await ctrl.close();
  }, skip: runPerf ? false : 'Set SSTERM_RUN_PERF=1 to run perf guard.');

  test(
    'Rust-authoritative path drains seq 1 2000000 without startup stalls',
    () async {
      final terminal = Terminal(maxLines: 5000)..resize(120, 40);
      final core = RustTerminalCore.open(
        columns: 120,
        rows: 40,
        maxScrollbackRows: 4960,
        libraryPath: _libraryPath(),
      );
      final bridge = RustTerminalBridge(core: core, terminal: terminal);
      final pipe = OutputPipe(terminal, terminalByteSink: bridge);
      final ctrl = StreamController<List<int>>();
      pipe.bind(ctrl.stream);

      final payload = BytesBuilder(copy: false);
      const encoder = Utf8Encoder();
      for (var value = 1; value <= 2000000; value++) {
        payload.add(encoder.convert('$value\r\n'));
      }
      final input = payload.takeBytes();

      final watch = Stopwatch()..start();
      ctrl.add(input);
      await Future<void>.delayed(Duration.zero);
      while (pipe.metrics.queuedBytes != 0 &&
          watch.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      watch.stop();

      expect(pipe.metrics.queuedBytes, 0);
      final visibleText = [
        for (
          var row = terminal.buffer.scrollBack;
          row < terminal.buffer.lines.length;
          row++
        )
          terminal.buffer.lines[row].toString(),
      ].join('\n');
      expect(visibleText, contains('2000000'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));

      pipe.dispose();
      bridge.close();
      core.close();
      await ctrl.close();
    },
    skip: runPerf ? false : 'Set SSTERM_RUN_PERF=1 to run perf guard.',
  );
}
