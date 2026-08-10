import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';

void main() {
  test('SSH bootstrap reports cwd', () {
    final script = File('lib/services/ssh_connection.dart').readAsStringSync();

    expect(script, contains(']7;file://'));
  });

  test('WSL launcher wrapper reports cwd', () {
    expect(buildInteractiveShellWrapper(), contains(']7;file://'));
  });
}
