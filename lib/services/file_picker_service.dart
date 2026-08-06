import 'dart:io';
import 'package:file_picker/file_picker.dart';

import '../utils/windows_powershell.dart';

/// Cross-platform file picker.
/// Mobile (iOS/Android): native Files/Storage picker via file_picker.
/// Desktop: native OS dialogs without Flutter plugins.
class FilePickerService {
  /// Pick a ZIP archive for a local Skill import.
  static Future<String?> pickZipFile() async {
    if (Platform.isIOS || Platform.isAndroid) {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      return result?.files.single.path;
    }
    if (Platform.isMacOS) return _pickMacOSZip();
    if (Platform.isWindows) return _pickWindowsZip();
    if (Platform.isLinux) return _pickLinuxZip();
    return null;
  }

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

  static Future<String?> _pickMacOSZip() async {
    const script =
        'set f to choose file of type {"zip"}\nreturn POSIX path of f';
    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  static Future<String?> _pickWindows() async {
    final script =
        windowsDpiAwarePrelude +
        r'''
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Title = "Select file to upload"
if ($d.ShowDialog() -eq "OK") { [Console]::Out.Write($d.FileName) }
''';
    final result = await runPowerShellEncoded(script);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  static Future<String?> _pickWindowsZip() async {
    final script =
        windowsDpiAwarePrelude +
        r'''
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.OpenFileDialog
$d.Title = "Select Skill ZIP"
$d.Filter = "ZIP files (*.zip)|*.zip"
if ($d.ShowDialog() -eq "OK") { [Console]::Out.Write($d.FileName) }
''';
    final result = await runPowerShellEncoded(script);
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

  static Future<String?> _pickLinuxZip() async {
    for (final cmd in [
      [
        'zenity',
        '--file-selection',
        '--title=Select Skill ZIP',
        '--file-filter=ZIP files | *.zip',
      ],
      ['kdialog', '--getopenfilename', '.', '*.zip'],
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
