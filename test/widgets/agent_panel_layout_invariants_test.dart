import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
