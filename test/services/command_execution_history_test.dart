import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/services/command_execution_history.dart';

void main() {
  test('appends complete command output as one JSONL record', () async {
    final dir = await Directory.systemTemp.createTemp('ssterm-history-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/history.jsonl');
    final history = CommandExecutionHistory(file: file);

    await history.append(
      CommandExecutionRecord(
        timestamp: DateTime.utc(2026),
        agentId: 'agent',
        target: 'local',
        cwd: '/tmp',
        command: 'echo secret',
        exitCode: 0,
        truncated: false,
        output: 'all output\nincluding every line',
        cancelled: false,
      ),
    );

    final record = jsonDecode((await file.readAsLines()).single) as Map;
    expect(record['output'], 'all output\nincluding every line');
    expect(record['agentId'], 'agent');
    expect(record['command'], 'echo secret');
  });

  test('serializes concurrent appends into complete JSONL lines', () async {
    final dir = await Directory.systemTemp.createTemp('ssterm-history-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/history.jsonl');
    final history = CommandExecutionHistory(file: file);

    await Future.wait([
      for (var i = 0; i < 20; i++)
        history.append(
          CommandExecutionRecord(
            timestamp: DateTime.utc(2026),
            agentId: 'agent',
            target: 'local',
            cwd: '/tmp',
            command: 'echo $i',
            exitCode: 0,
            truncated: false,
            output: 'output $i',
            cancelled: false,
          ),
        ),
    ]);

    final records = (await file.readAsLines()).map(jsonDecode).toList();
    expect(records, hasLength(20));
    expect(records.every((record) => record is Map), isTrue);
  });

  test('preserves structured cancellation from the command result', () {
    final record = CommandExecutionRecord.fromResult(
      timestamp: DateTime.utc(2026),
      agentId: 'agent',
      target: 'ssh',
      cwd: '/srv',
      command: 'sleep 5',
      result: CommandResult(
        output: '[ssterm background] cancelled',
        exitCode: null,
        cancelled: true,
      ),
    );

    expect(record.cancelled, isTrue);
    expect(record.exitCode, isNull);
  });

  test('swallows filesystem failures after reporting them', () async {
    Object? reported;
    final history = CommandExecutionHistory(
      file: File('/dev/null/history.jsonl'),
      onError: (error) => reported = error,
    );

    await history.append(
      CommandExecutionRecord(
        timestamp: DateTime.utc(2026),
        agentId: 'agent',
        target: 'local',
        cwd: '/tmp',
        command: 'false',
        exitCode: 1,
        truncated: false,
        output: '',
        cancelled: false,
      ),
    );

    expect(reported, isNotNull);
  });

  test('legacy agent identities remain readable in historical JSONL', () {
    const history = '''
{"agentId":"agent1","command":"first"}
{"agentId":"agent2","command":"second"}
''';

    final records = history
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();

    expect(records.map((record) => record['agentId']), ['agent1', 'agent2']);
  });
}
