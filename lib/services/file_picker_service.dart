import 'dart:io';
import 'package:file_picker/file_picker.dart';

/// Cross-platform file picker.
/// Mobile (iOS/Android): native Files/Storage picker via file_picker.
/// Desktop: native OS dialogs without Flutter plugins.
class FilePickerService {
  static Future<String?> pickFile() async {
    if (Platform.isIOS || Platform.isAndroid) return _pickMobile();
    if (Platform.isMacOS) return _pickMacOS();
    if (Platform.isWindows) return _pickWindows();
    if (Platform.isLinux) return _pickLinux();
    return null;
  }

  static Future<String?> _pickMobile() async {
    final result = await FilePicker.pickFiles(type: FileType.any);
    return result?.files.single.path;
  }

  static Future<String?> _pickMacOS() async {
    const script = 'set f to choose file\nreturn POSIX path of f';
    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  static Future<String?> _pickWindows() async {
    const ps = '[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null; '
        r'$d = New-Object System.Windows.Forms.OpenFileDialog; '
        r'$d.Title = "Select file to upload"; '
        r'if ($d.ShowDialog() -eq "OK") { $d.FileName }';
    final result = await Process.run('powershell', ['-Command', ps]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  static Future<String?> _pickLinux() async {
    // Try zenity first, then kdialog
    for (final cmd in [
      ['zenity', '--file-selection', '--title=Select file to upload'],
      ['kdialog', '--getopenfilename', '.'],
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
