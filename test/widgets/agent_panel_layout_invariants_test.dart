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

  test('execution output cards default to a four-line collapsed preview', () {
    final content = File(
      'lib/widgets/ai_assistant_panel_content.dart',
    ).readAsStringSync();
    final widgets = File(
      'lib/widgets/ai_assistant_panel_widgets.dart',
    ).readAsStringSync();
    final mcpResultCard = content.substring(
      content.indexOf('class _McpResultCard'),
      content.length,
    );

    expect(widgets, contains('static const _kCollapsedLines = 4;'));
    expect(
      mcpResultCard,
      contains('class _McpResultCard extends StatefulWidget'),
    );
    expect(mcpResultCard, contains('static const _kCollapsedLines = 4;'));
    expect(mcpResultCard, contains("'Collapse'"));
    expect(mcpResultCard, contains('more lines'));
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
      'lib/widgets/ai_assistant_panel_execution.dart',
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

  test('panel delegates scheduling to a UI-independent runner', () {
    final adapter = File(
      'lib/widgets/ai_assistant_panel_loop.dart',
    ).readAsStringSync();
    final runner = File('lib/services/agent_runner.dart').readAsStringSync();
    expect(adapter, contains('AgentRunner('));
    expect(adapter, contains('runner.subscribe('));
    expect(adapter, isNot(contains('while (')));
    expect(runner, isNot(contains('package:flutter/')));
    expect(runner, isNot(contains('setState')));
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
      'lib/widgets/ai_assistant_panel_execution.dart',
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
