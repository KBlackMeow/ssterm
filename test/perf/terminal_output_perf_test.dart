import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:xterm/xterm.dart';

void main() {
  final runPerf = Platform.environment['SSTERM_RUN_PERF'] == '1';

  test(
    'large output flood drains without pathological delay',
    () async {
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

      expect(
        accepted.fold<int>(0, (sum, value) => sum + value),
        payload.length,
      );
      expect(terminal.buffer.lines.length, greaterThan(1000));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));

      pipe.dispose();
      await ctrl.close();
    },
    skip: runPerf ? false : 'Set SSTERM_RUN_PERF=1 to run perf guard.',
  );
}
