import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SSH execute waits for PTY acceptance before sending exec', () {
    final source = File(
      'packages/dartssh2/lib/src/ssh_client.dart',
    ).readAsStringSync();
    final methodStart = source.indexOf('Future<SSHSession> execute(');
    final methodEnd = source.indexOf('Future<SSHSession> shell(', methodStart);
    final execute = source.substring(methodStart, methodEnd);

    final ptyRequest = execute.indexOf(
      'final ptyOk = await channelController.sendPtyReq(',
    );
    final ptyFailure = execute.indexOf('if (!ptyOk)', ptyRequest);
    final execRequest = execute.indexOf(
      'await channelController.sendExec(command)',
    );

    expect(ptyRequest, isNonNegative);
    expect(ptyFailure, greaterThan(ptyRequest));
    expect(execRequest, greaterThan(ptyFailure));
    expect(execute, isNot(contains('Future<bool>? ptyOk')));
  });
}
