import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/services/command_feedback_formatter.dart';

void main() {
  test('twenty fixed output sizes measure feedback byte reduction', () {
    const baseline = CommandFeedbackFormatter(
      maxFeedbackBytes: 8 * 1024,
      headBytes: 4 * 1024,
      tailBytes: 4 * 1024,
    );
    const current = CommandFeedbackFormatter();
    const sizes = <int>[
      64,
      128,
      256,
      512,
      1024,
      2048,
      4096,
      5000,
      6000,
      7000,
      8000,
      9000,
      10000,
      12000,
      16000,
      20000,
      24000,
      30000,
      64000,
      256000,
    ];
    var oldBytes = 0;
    var newBytes = 0;
    for (final size in sizes) {
      final result = CommandResult(output: 'x' * size, exitCode: 0);
      oldBytes += utf8.encode(baseline.format('build', result)).length;
      newBytes += utf8.encode(current.format('build', result)).length;
    }
    final reduction = 100 * (oldBytes - newBytes) / oldBytes;
    // This measures only command feedback bytes, not provider token usage.
    expect(reduction, greaterThan(20));
    expect(
      newBytes,
      lessThan(oldBytes),
      reason: '20 cases: baseline=$oldBytes bytes, current=$newBytes bytes',
    );
  });
}
