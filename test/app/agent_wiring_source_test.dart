import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main view owns one background-only Agent overlay', () {
    final source = File('lib/app/main_views.dart').readAsStringSync();
    expect('AiAssistantOverlay('.allMatches(source), hasLength(1));
    expect(source, contains('_executeAgentCommand'));

    final overlayStart = source.indexOf('body = AiAssistantOverlay(');
    final overlayEnd = source.indexOf('\n    return body;', overlayStart);
    expect(overlayStart, isNonNegative);
    expect(overlayEnd, greaterThan(overlayStart));
    final overlayWiring = source.substring(overlayStart, overlayEnd);
    final visibleTerminalCallbacks = [
      ['on', 'Insert', ':'].join(),
      ['on', 'Execute', ':'].join(),
      ['on', 'GetShellIntegrationActive', ':'].join(),
      ['on', 'TerminalLockChanged', ':'].join(),
      ['tab', '.', 'terminal', '!', '.', 'paste'].join(),
      ['_execute', 'OnTab'].join(),
    ];
    for (final callback in visibleTerminalCallbacks) {
      expect(overlayWiring, isNot(contains(callback)), reason: callback);
    }

    final panel = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();
    for (final callback in visibleTerminalCallbacks.take(4)) {
      expect(panel, isNot(contains(callback)), reason: callback);
    }

    final host = File('lib/app/main_ssh.dart').readAsStringSync();
    expect(host, contains('tab.isAgentExecutionCancelled'));
    expect(host, contains('tab.applyAgentCommandResult(result)'));
  });

  test('Agent header exposes the existing clear-chat action', () {
    final panel = File('lib/widgets/ai_assistant_panel.dart').readAsStringSync();
    final content = File(
      'lib/widgets/ai_assistant_panel_content.dart',
    ).readAsStringSync();
    final widgets = File(
      'lib/widgets/ai_assistant_panel_widgets.dart',
    ).readAsStringSync();

    expect(panel, contains('onClear: _clearChat'));
    expect(content, contains('required this.onClear'));
    expect(content, contains('onClear: onClear'));
    expect(widgets, contains('final VoidCallback onClear'));
    expect(widgets, contains("message: 'Clear conversation'"));
  });

  test('Git Bash file tools normalize the shell cwd for host I/O', () {
    final source = File('lib/app/main_views.dart').readAsStringSync();

    expect(source, contains('pathNormalizer:'));
    expect(source, contains('nativePathForLocalShell(shell, path)'));
  });

  test('README describes Agent context as scoped rather than complete', () {
    final readme = File('README.md').readAsStringSync();

    expect(readme, isNot(contains('all with full terminal context')));
    expect(readme, contains('tab-scoped session context'));
  });

  test('command message docs do not claim ANSI-clean output', () {
    final source = File(
      'lib/widgets/ai_assistant_panel_models.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('already cleaned of ANSI')));
    expect(source, contains('may still contain ANSI escape sequences'));
  });
}
