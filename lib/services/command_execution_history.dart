/// 提供 Agent 命令执行历史的本地持久化能力。记录用于后续查看和上下文整理；
/// 写入失败不会改变命令本身的执行结果。

import 'dart:convert';
import 'dart:io';

import '../io/output_pipe.dart';
import '../utils/app_dir.dart';

/// 可持久化的命令历史项，记录执行时间、Agent/目标、工作目录、命令、退出码、
/// 取消和输出截断状态。敏感输出的处理由执行结果生成逻辑负责。
class CommandExecutionRecord {
  const CommandExecutionRecord({
    required this.timestamp,
    required this.agentId,
    required this.target,
    required this.cwd,
    required this.command,
    required this.exitCode,
    required this.truncated,
    required this.output,
    required this.cancelled,
  });

  factory CommandExecutionRecord.fromResult({
    required DateTime timestamp,
    required String agentId,
    required String target,
    required String? cwd,
    required String command,
    required CommandResult? result,
  }) => CommandExecutionRecord(
    timestamp: timestamp,
    agentId: agentId,
    target: target,
    cwd: cwd,
    command: command,
    exitCode: result?.exitCode,
    truncated: result?.truncated ?? false,
    output: result?.output ?? '',
    cancelled: result?.cancelled ?? true,
  );

  final DateTime timestamp;
  final String agentId;
  final String target;
  final String? cwd;
  final String command;
  final int? exitCode;
  final bool truncated;
  final String output;
  final bool cancelled;

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'agentId': agentId,
    'target': target,
    'cwd': cwd,
    'command': command,
    'exitCode': exitCode,
    'truncated': truncated,
    'output': output,
    'cancelled': cancelled,
  };
}

/// 管理 Agent 命令历史的追加和读取。写入失败通过可选错误回调上报，不应阻断当前
/// Agent 会话的工具执行。
class CommandExecutionHistory {
  CommandExecutionHistory({this.file, this.onError});

  final File? file;
  final void Function(Object error)? onError;
  Future<void> _pending = Future.value();

  Future<void> append(CommandExecutionRecord record) {
    _pending = _pending.then((_) async {
      try {
        final target = file ?? await _defaultFile();
        await target.parent.create(recursive: true);
        await target.writeAsString(
          '${jsonEncode(record.toJson())}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (error) {
        onError?.call(error);
      }
    });
    return _pending;
  }

  static Future<File> _defaultFile() async {
    final base = await appDataDir();
    return File('${base.path}/logs/agent-command-history.jsonl');
  }
}
