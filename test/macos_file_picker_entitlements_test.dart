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

  test('macOS build declares why terminal commands modify app bundles', () {
    final infoPlist = File('macos/Runner/Info.plist').readAsStringSync();

    expect(
      infoPlist,
      contains('<key>NSAppBundlesUsageDescription</key>'),
      reason:
          'macOS requires an App Management usage description before SSTerm '
          'can let terminal commands modify another application bundle.',
    );
  });
}
