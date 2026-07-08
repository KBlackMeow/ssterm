import 'dart:convert';

import '../io/output_pipe.dart';

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

    if (result?.truncated == true) {
      header.writeln(
        '[capture_truncated=true reason="output exceeded ssterm capture cap; head and/or tail may be missing"]',
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
