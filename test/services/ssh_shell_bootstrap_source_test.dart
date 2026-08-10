import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';

void main() {
  test('SSH bootstrap reports cwd without OSC 133', () {
    final script = File('lib/services/ssh_connection.dart').readAsStringSync();

    expect(script, contains(']7;file://'));
    expect(script, isNot(contains(']133;')));
    expect(script, isNot(contains('__ssterm_osc133')));
  });

  test('WSL launcher wrapper has no OSC 133', () {
    expect(buildInteractiveShellWrapper(), isNot(contains(']133;')));
  });
}
