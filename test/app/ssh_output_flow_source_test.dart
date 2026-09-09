import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every interactive SSH output pipe keeps channel input flowing', () {
    final sshSource = File('lib/app/main_ssh.dart').readAsStringSync();
    final localSource = File('lib/app/main_local.dart').readAsStringSync();
    const setting = 'pauseSourceOnBackpressure: false';

    // Initial SSH session, split pane, and reconnect.
    expect(setting.allMatches(sshSource), hasLength(3));
    // Restarting an ended SSH pane is implemented in main_local.dart.
    expect(setting.allMatches(localSource), hasLength(1));
  });
}
