import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main view owns one background-only Agent overlay', () {
    final source = File('lib/app/main_views.dart').readAsStringSync();
    expect('AiAssistantOverlay('.allMatches(source), hasLength(1));
    expect(source, contains('_executeAgentCommand'));

    final host = File('lib/app/main_ssh.dart').readAsStringSync();
    expect(host, contains('tab.isAgentExecutionCancelled'));
    expect(host, contains('tab.applyAgentCommandResult(result)'));
  });
}
