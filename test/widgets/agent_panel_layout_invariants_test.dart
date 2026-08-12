import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tool-call expansion tile has a local Material surface', () {
    final source = File(
      'lib/widgets/ai_assistant_panel_content.dart',
    ).readAsStringSync();
    final toolCallCard = source.substring(
      source.indexOf('class _ToolCallCard'),
      source.indexOf('class _McpResultCard'),
    );

    expect(toolCallCard, contains('return Material('));
    expect(toolCallCard, contains('clipBehavior: Clip.antiAlias'));
    expect(toolCallCard, contains('child: ExpansionTile('));
  });

  test('top-level collapsible cards have no assistant-body indentation', () {
    final source = File(
      'lib/widgets/ai_assistant_panel_content.dart',
    ).readAsStringSync();

    final commandResultBranch = source.substring(
      source.indexOf('if (msg.isSystem)'),
      source.indexOf('// File-write proposal'),
    );
    final toolCallBranch = source.substring(
      source.indexOf('final toolCalls = msg.toolCallData;'),
      source.indexOf('// `== true`'),
    );

    expect(commandResultBranch, contains('EdgeInsets.only(bottom: 8)'));
    expect(commandResultBranch, isNot(contains('left: 32')));
    expect(toolCallBranch, contains('EdgeInsets.only(bottom: 12)'));
    expect(toolCallBranch, isNot(contains('left: 32')));
  });

  test('command risk gate and result card expose all three levels', () {
    final loop = File(
      'lib/widgets/ai_assistant_panel_loop.dart',
    ).readAsStringSync();
    final widgets = File(
      'lib/widgets/ai_assistant_panel_widgets.dart',
    ).readAsStringSync();
    final content = File(
      'lib/widgets/ai_assistant_panel_content.dart',
    ).readAsStringSync();

    expect(loop, contains('CommandRisk.assess('));
    expect(loop, contains('CommandRisk.needsConfirmation('));
    expect(loop, isNot(contains('verdict != null || !_autoExecute')));
    expect(widgets, contains("label: '普通'"));
    expect(widgets, contains("label: '警告'"));
    expect(widgets, contains("label: '危险'"));
    expect(content, contains('审慎模式：普通命令直接执行，警告和危险命令需要确认'));
  });

  test('agent loop reuses one stream client session and hardens retries', () {
    final loop = File(
      'lib/widgets/ai_assistant_panel_loop.dart',
    ).readAsStringSync();
    final tooling = File(
      'lib/widgets/ai_assistant_panel_tooling.dart',
    ).readAsStringSync();

    expect(loop, contains('_streamSession = AgentStreamClientSession();'));
    expect(loop, contains('streamSession: streamSession'));
    expect(loop, contains('streamSession.close();'));
    expect(loop, contains('_streamSessionPausedGeneration = gen'));
    expect(
      tooling,
      contains('required AgentStreamClientSession streamSession'),
    );
    expect(tooling, contains('session: streamSession'));
    expect(tooling, contains('streamSession.reset();'));
    expect(tooling, contains('hasToolCalls: nativeToolCalls.isNotEmpty'));
    expect(tooling, contains('identical(_cancelStream, cancelAttempt)'));
    expect(tooling, contains(r'backoff_ms=${retryDelay.inMilliseconds}'));
    expect(tooling, contains('AgentStreamLogSanitizer.message(e)'));
  });

  test('panel disposal invalidates command cancellation generation', () {
    final source = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();
    final disposeBody = source.substring(
      source.indexOf('void dispose() {'),
      source.indexOf('void _cancelAgent()'),
    );

    expect(disposeBody, contains('_generation++;'));
  });

  test('every command result card carries and displays execution purpose', () {
    final models = File(
      'lib/widgets/ai_assistant_panel_models.dart',
    ).readAsStringSync();
    final loop = File(
      'lib/widgets/ai_assistant_panel_loop.dart',
    ).readAsStringSync();
    final content = File(
      'lib/widgets/ai_assistant_panel_content.dart',
    ).readAsStringSync();
    final widgets = File(
      'lib/widgets/ai_assistant_panel_widgets.dart',
    ).readAsStringSync();

    expect(models, contains('final String? commandPurpose;'));
    expect(models, contains('commandPurpose: commandPurpose'));
    expect(loop, contains('commandPurpose: toolCall.reason'));
    expect(content, contains('purpose: msg.commandPurpose'));
    expect(widgets, contains(r"'执行目的：$displayPurpose'"));
    expect(widgets, contains("'AI 未提供'"));
  });
}
