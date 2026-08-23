import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// Cross-platform file picker.
/// Uses the platform's native dialog through `file_picker` on every platform.
class FilePickerService {
  static Future<void>? _macOsEntitlementsCheckSkip;

  /// Pick a ZIP archive for a local Skill import.
  static Future<String?> pickZipFile() =>
      _pickFiles(type: FileType.custom, allowedExtensions: const ['zip']);

  /// Pick a wallpaper image.
  ///
  /// Starts in the user's Pictures folder so the native dialog opens on
  /// something that actually contains images. The Win32 file dialog used on
  /// Windows otherwise opens at the process working directory — typically
  /// the app's install folder, which has no image files, so the filtered
  /// list renders completely empty and the picker looks broken.
  static Future<String?> pickImageFile() => _pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
    initialDirectory: _picturesDirectory(),
  );

  /// Pick a file without restricting its type.
  static Future<String?> pickFile() => _pickFiles(type: FileType.any);

  static Future<String?> _pickFiles({
    required FileType type,
    List<String>? allowedExtensions,
    String? initialDirectory,
  }) async {
    if (Platform.isMacOS) {
      await (_macOsEntitlementsCheckSkip ??=
          FilePicker.skipEntitlementsChecks());
    }
    final result = await FilePicker.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      initialDirectory: initialDirectory,
    );
    return result?.files.single.path;
  }

  /// The user's Pictures directory on desktop, or `null` to let the picker
  /// fall back to its platform default. Windows keeps it under `USERPROFILE`,
  /// POSIX under `HOME`.
  static String? _picturesDirectory() {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final pictures = Platform.isWindows
        ? '$home\\Pictures'
        : p.join(home, 'Pictures');
    return Directory(pictures).existsSync() ? pictures : home;
  }
}
