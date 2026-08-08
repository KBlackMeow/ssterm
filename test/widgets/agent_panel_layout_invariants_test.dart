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
}
