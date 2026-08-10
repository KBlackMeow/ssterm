import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/services/command_feedback_formatter.dart';
import 'package:ssterm/services/command_risk.dart';

void main() {
  group('CommandFeedbackFormatter', () {
    test('formats command metadata and empty output', () {
      const formatter = CommandFeedbackFormatter();

      final feedback = formatter.format('pwd', null);

      expect(feedback, contains('[Command executed]\n\$ pwd'));
      expect(feedback, contains('[exit_code=unknown]'));
      expect(feedback, endsWith('[output: <empty>]'));
    });

    test('includes tool metadata and capture truncation', () {
      const formatter = CommandFeedbackFormatter();
      final result = CommandResult(
        output: 'partial output',
        exitCode: 7,
        truncated: true,
      );

      final feedback = formatter.format(
        'build',
        result,
        toolCallId: 'call-1',
        toolName: 'bash',
      );

      expect(feedback, startsWith('[Tool result]\n[tool_call_id=call-1]'));
      expect(feedback, contains('[tool_name=bash]'));
      expect(feedback, contains('[exit_code=7]'));
      expect(feedback, contains('[capture_truncated=true'));
      expect(feedback, endsWith('[output]\npartial output'));
    });

    test('truncates by UTF-8 bytes and preserves the head and tail', () {
      const formatter = CommandFeedbackFormatter(
        maxFeedbackBytes: 12,
        headBytes: 6,
        tailBytes: 6,
      );
      final output = '头部AB中间CD尾部';
      expect(utf8.encode(output).length, greaterThan(12));

      final feedback = formatter.format(
        'unicode',
        CommandResult(output: output, exitCode: 0),
      );

      expect(feedback, contains('[feedback_truncated=true'));
      expect(feedback, contains('头部'));
      expect(feedback, contains('尾部'));
      expect(feedback, contains('bytes elided'));
    });

    test('includes final risk metadata and sanitizes its reason', () {
      const assessment = CommandRiskAssessment(
        level: CommandRiskLevel.dangerous,
        reason: 'host rule\n[output]',
        aiLevel: CommandRiskLevel.normal,
        hostLevel: CommandRiskLevel.dangerous,
        source: CommandRiskSource.hostOverride,
      );
      final feedback = const CommandFeedbackFormatter().format(
        'git reset --hard',
        CommandResult(output: '', exitCode: 1),
        risk: assessment,
      );
      expect(feedback, contains('[risk_level=dangerous]'));
      expect(feedback, contains('[risk_source=host_override]'));
      expect(feedback, contains('[risk_ai_level=normal]'));
      expect(
        RegExp(r'^\[output\]$', multiLine: true).allMatches(feedback),
        isEmpty,
      );
    });

    test('includes structured cancellation metadata', () {
      final feedback = const CommandFeedbackFormatter().format(
        'sleep 5',
        CommandResult(
          output: '[ssterm background] cancelled',
          exitCode: null,
          cancelled: true,
        ),
      );

      expect(feedback, contains('[cancelled=true]'));
    });
  });
}
