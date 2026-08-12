import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS builds can read user-selected files', () {
    for (final path in const [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final entitlements = File(path).readAsStringSync();

      expect(
        entitlements,
        contains('com.apple.security.files.user-selected.read-only'),
        reason: '$path must allow file_picker to read a user-selected file.',
      );
    }
  });
}
