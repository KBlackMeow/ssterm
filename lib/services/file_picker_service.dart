import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// Cross-platform file picker.
/// Uses the platform's native dialog through `file_picker` on every platform.
class FilePickerService {
  static Future<void>? _macOsEntitlementsCheckSkip;

  /// Pick a ZIP archive for a local Skill import.
  static Future<String?> pickZipFile() =>
      _pickFiles(type: FileType.custom, allowedExtensions: const ['zip']);

  /// Pick a wallpaper image.
  static Future<String?> pickImageFile() => _pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
  );

  /// Pick a file without restricting its type.
  static Future<String?> pickFile() => _pickFiles(type: FileType.any);

  static Future<String?> _pickFiles({
    required FileType type,
    List<String>? allowedExtensions,
  }) async {
    if (Platform.isMacOS) {
      await (_macOsEntitlementsCheckSkip ??=
          FilePicker.skipEntitlementsChecks());
    }
    final result = await FilePicker.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
    );
    return result?.files.single.path;
  }
}
