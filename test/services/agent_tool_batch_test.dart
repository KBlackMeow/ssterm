import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_output_store.dart';
import 'package:ssterm/services/agent_read_tools.dart';
import 'package:ssterm/services/agent_tool_batch.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';
import 'package:ssterm/services/file_write_service.dart';

AgentToolCall call(String id, String name, Map<String, Object?> arguments) =>
    AgentToolCall.fromRaw(id: id, name: name, arguments: arguments)!;

void main() {
  final registry = AgentToolRegistry.build(webSearchEnabled: true);
  final bashArguments = <String, Object?>{
    'command': 'pwd',
    'reason': 'Find the current directory.',
    'risk_level': 'normal',
    'risk_reason': 'Read only.',
  };

  test('accepts a homogeneous shell batch', () {
    expect(
      AgentToolBatch.rejectionReason([
        call('one', 'bash', bashArguments),
        call('two', 'bash', bashArguments),
      ], registry),
      isNull,
    );
  });

  test('rejects mixed batches before execution', () {
    expect(
      AgentToolBatch.rejectionReason([
        call('one', 'bash', bashArguments),
        call('two', 'web_search', {'query': 'test'}),
      ], registry),
      contains('one tool call at a time'),
    );
  });

  test('rejects malformed or truncated calls', () {
    expect(
      AgentToolBatch.rejectionReason([
        call('one', 'bash', {'command': 'pwd'}),
      ], registry),
      contains('Missing required argument'),
    );
    expect(
      AgentToolBatch.rejectionReason(
        [call('one', 'bash', bashArguments)],
        registry,
        finishReason: 'length',
      ),
      contains('output limit'),
    );
  });

  test('rejects duplicate ids and invalid enum values', () {
    expect(
      AgentToolBatch.rejectionReason([
        call('one', 'bash', bashArguments),
        call('one', 'bash', bashArguments),
      ], registry),
      contains('unique'),
    );
    expect(
      AgentToolBatch.rejectionReason([
        call('one', 'bash', {...bashArguments, 'risk_level': 'safe'}),
      ], registry),
      contains('Invalid value'),
    );
  });

  test('legacy batches reject conflicting tool shapes', () {
    expect(AgentToolBatch.legacyRejectionReason(['bash', 'read_file']), isNull);
    expect(AgentToolBatch.legacyRejectionReason(['bash', 'bash']), isNull);
    expect(
      AgentToolBatch.legacyRejectionReason(['read_file', 'grep_file']),
      isNull,
    );
  });

  test('accepts a bounded mixed read-only batch', () {
    expect(
      AgentToolBatch.rejectionReason([
        call('one', 'read_file', {'path': 'a.txt', 'offset': 0}),
        call('two', 'grep_file', {'path': 'b.txt', 'pattern': 'x'}),
      ], registry),
      isNull,
    );
    expect(
      AgentToolBatch.rejectionReason([
        for (var index = 0; index < 9; index++)
          call('read_$index', 'read_file', {'path': 'a.txt', 'offset': 0}),
      ], registry),
      contains('one tool call at a time'),
    );
  });

  test('accepts shell and bounded reads in one native batch', () {
    expect(
      AgentToolBatch.rejectionReason([
        call('shell', 'bash', bashArguments),
        call('search', 'grep_file', {
          'path': 'logs/build.log',
          'pattern': 'ERROR',
        }),
      ], registry),
      isNull,
    );
    expect(
      AgentToolBatch.rejectionReason([
        call('shell', 'bash', bashArguments),
        call('search', 'grep_file', {
          'path': 'logs/build.log',
          'pattern': 'ERROR',
        }),
        call('search_web', 'web_search', {'query': 'x'}),
      ], registry),
      contains('one tool call at a time'),
    );
  });

  test('each native call receives one result in original order', () {
    final results = AgentToolBatch.completeResults(
      [call('one', 'bash', bashArguments), call('two', 'bash', bashArguments)],
      const [
        AgentToolResult(toolCallId: 'two', content: 'done'),
        AgentToolResult(toolCallId: 'two', content: 'duplicate'),
      ],
    );
    expect(results.map((result) => result.toolCallId), ['one', 'two']);
    expect(results.first.isError, isTrue);
    expect(results.last.content, 'done');
  });

  test('mixed read batch keeps successes and failures paired', () async {
    final root = await Directory.systemTemp.createTemp('ssterm-read-batch-');
    try {
      final path = '${root.path}/sample.txt';
      await File(path).writeAsString('alpha\nbeta\n');
      final calls = [
        call('search', 'grep_file', {'path': path, 'pattern': 'beta'}),
        call('missing', 'read_file', {
          'path': '${root.path}/missing.txt',
          'offset': 0,
        }),
        call('page', 'read_file', {'path': path, 'offset': 0}),
      ];
      expect(AgentToolBatch.rejectionReason(calls, registry), isNull);

      final reader = AgentReadTools(
        outputStore: AgentOutputStore(directory: root, sessionId: 'batch'),
        fileSystem: const LocalFileSystemAdapter(),
      );
      final produced = <AgentToolResult>[];
      for (final toolCall in calls) {
        final read = await reader.execute(toolCall.name, toolCall.arguments);
        produced.add(
          AgentToolResult(
            toolCallId: toolCall.id,
            content: read.content,
            isError: read.isError,
          ),
        );
      }
      final paired = AgentToolBatch.completeResults(calls, produced);
      expect(paired.map((result) => result.toolCallId), [
        'search',
        'missing',
        'page',
      ]);
      expect(paired.map((result) => result.isError), [false, true, false]);
      expect(paired.first.content, contains('2: beta'));
      expect(paired.last.content, contains('alpha'));
    } finally {
      await root.delete(recursive: true);
    }
  });
}
