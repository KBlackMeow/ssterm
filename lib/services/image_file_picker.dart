import 'dart:io';

/// Opens a native image file picker. Uses AppleScript on macOS (no Flutter plugin).
class ImageFilePicker {
  static bool get isSupported => Platform.isMacOS;

  static Future<String?> pickPath() async {
    if (!isSupported) return null;
    return _pickMacOS();
  }

  static Future<String?> _pickMacOS() async {
    const script = r'''
set chosenFile to choose file with prompt "Choose wallpaper" of type {"public.image", "PNG", "JPEG", "GIF", "TIFF", "BMP", "WEBP"}
return POSIX path of chosenFile
''';
    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }
}
