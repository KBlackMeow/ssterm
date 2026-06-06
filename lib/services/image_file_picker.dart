import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../utils/windows_powershell.dart';

/// Opens a native image file picker.
/// Mobile (iOS/Android): native picker via file_picker.
/// Desktop: native OS dialogs without Flutter plugins
/// (AppleScript on macOS, OpenFileDialog on Windows, zenity/kdialog on Linux).
class ImageFilePicker {
  /// Image picking is supported on every platform we ship to.
  static bool get isSupported =>
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isIOS ||
      Platform.isAndroid;

  static const _extensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];

  static Future<String?> pickPath() async {
    if (Platform.isIOS || Platform.isAndroid) return _pickMobile();
    if (Platform.isMacOS) return _pickMacOS();
    if (Platform.isWindows) return _pickWindows();
    if (Platform.isLinux) return _pickLinux();
    return null;
  }

  static Future<String?> _pickMobile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _extensions,
    );
    return result?.files.single.path;
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

  static Future<String?> _pickWindows() async {
    final script = windowsDpiAwarePrelude +
        r'''
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Title = "Choose wallpaper"
$d.Filter = "Images|*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp|All files|*.*"
if ($d.ShowDialog() -eq "OK") { [Console]::Out.Write($d.FileName) }
''';
    final result = await runPowerShellEncoded(script);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  static Future<String?> _pickLinux() async {
    for (final cmd in [
      [
        'zenity',
        '--file-selection',
        '--title=Choose wallpaper',
        '--file-filter=Images | *.png *.jpg *.jpeg *.gif *.webp *.bmp',
      ],
      ['kdialog', '--getopenfilename', '.', 'image/png image/jpeg image/gif image/webp image/bmp'],
    ]) {
      try {
        final result = await Process.run(cmd.first, cmd.skip(1).toList());
        if (result.exitCode == 0) {
          final path = (result.stdout as String).trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
