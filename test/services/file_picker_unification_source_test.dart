import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every local file selection uses FilePickerService and file_picker', () {
    final pickerService = File(
      'lib/services/file_picker_service.dart',
    ).readAsStringSync();
    final settingsSheet = File(
      'lib/views/settings/settings_sheet.dart',
    ).readAsStringSync();

    expect(pickerService, contains('static Future<String?> pickImageFile()'));
    expect(
      pickerService,
      contains(
        "allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']",
      ),
    );
    expect(pickerService, isNot(contains('runPowerShellEncoded')));
    expect(pickerService, isNot(contains('Process.run')));
    expect(pickerService, contains('FilePicker.skipEntitlementsChecks()'));
    expect(settingsSheet, contains('FilePickerService.pickImageFile()'));
    expect(File('lib/services/image_file_picker.dart').existsSync(), isFalse);
    final powerShellUtility = File(
      'lib/utils/windows_powershell.dart',
    ).readAsStringSync();
    expect(powerShellUtility, isNot(contains('runPowerShellEncoded')));
  });
}
