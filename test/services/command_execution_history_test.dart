import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
        agentId: 'agent2',
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
    expect(record['agentId'], 'agent2');
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
            agentId: 'agent2',
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

  test('swallows filesystem failures after reporting them', () async {
    Object? reported;
    final history = CommandExecutionHistory(
      file: File('/dev/null/history.jsonl'),
      onError: (error) => reported = error,
    );

    await history.append(
      CommandExecutionRecord(
        timestamp: DateTime.utc(2026),
        agentId: 'agent1',
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
}
