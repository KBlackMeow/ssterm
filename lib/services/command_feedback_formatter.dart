import 'dart:convert';

import '../io/output_pipe.dart';
import 'command_risk.dart';
import 'agent_output_store.dart';

class CommandFeedbackFormatter {
  const CommandFeedbackFormatter({
    this.maxFeedbackBytes = 8 * 1024,
    this.headBytes = 4 * 1024,
    this.tailBytes = 4 * 1024,
  }) : assert(headBytes + tailBytes <= maxFeedbackBytes);

  final int maxFeedbackBytes;
  final int headBytes;
  final int tailBytes;

  String format(
    String command,
    CommandResult? result, {
    String? toolCallId,
    String toolName = 'bash',
    CommandRiskAssessment? risk,
    AgentOutputReference? artifact,
  }) {
    final exit = result?.exitCode;
    final rawBytes = utf8.encode(result?.output ?? '');
    final body = _truncate(rawBytes);
    final header = StringBuffer();

    if (toolCallId != null) {
      header
        ..writeln('[Tool result]')
        ..writeln('[tool_call_id=$toolCallId]')
        ..writeln('[tool_name=$toolName]');
    }
    header
      ..writeln('[Command executed]')
      ..writeln('\$ $command')
      ..writeln('[exit_code=${exit ?? 'unknown'}]');

    if (result?.cancelled == true) {
      header.writeln('[cancelled=true]');
    }

    if (risk != null) {
      header
        ..writeln('[risk_level=${risk.level.name}]')
        ..writeln('[risk_source=${_snake(risk.source.name)}]');
      if (risk.source == CommandRiskSource.hostOverride &&
          risk.aiLevel != null) {
        header.writeln('[risk_ai_level=${risk.aiLevel!.name}]');
      }
      header.writeln('[risk_reason=${_metadata(risk.reason)}]');
    }

    if (result?.truncated == true) {
      header.writeln(
        '[capture_truncated=true reason="output exceeded ssterm capture cap; head and/or tail may be missing"]',
      );
    }
    if (artifact != null) {
      header.writeln(
        '[output_artifact id=${artifact.id} stored_bytes=${artifact.storedBytes} '
        'original_bytes=${artifact.originalBytes} truncated=${artifact.truncated}]',
      );
    }
    if (rawBytes.length > maxFeedbackBytes) {
      header.writeln(
        '[feedback_truncated=true reason="middle elided to fit context; ${rawBytes.length} bytes captured, ~8 KB sent"]',
      );
    }
    if (body.isEmpty) {
      header.writeln('[output: <empty>]');
    } else {
      header
        ..writeln('[output]')
        ..writeln(body);
    }
    return header.toString().trimRight();
  }

  String _metadata(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ')
        .replaceAll(']', r'\]')
        .trim();
    return cleaned.length <= 240 ? cleaned : cleaned.substring(0, 240);
  }

  String _snake(String value) => value.replaceAllMapped(
    RegExp(r'[A-Z]'),
    (match) => '_${match.group(0)!.toLowerCase()}',
  );

  String _truncate(List<int> bytes) {
    if (bytes.length <= maxFeedbackBytes) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    final head = utf8.decode(bytes.sublist(0, headBytes), allowMalformed: true);
    final tail = utf8.decode(
      bytes.sublist(bytes.length - tailBytes),
      allowMalformed: true,
    );
    final elided = bytes.length - headBytes - tailBytes;
    return '$head\n... [$elided bytes elided] ...\n$tail';
  }
}
