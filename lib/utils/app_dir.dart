import 'dart:io';

/// Returns the app's writable data directory, safe on all platforms including iOS.
Future<Directory> appDataDir() async {
  final String base;
  if (Platform.isIOS) {
    // On iOS, HOME is unset. Derive the app container from the temp dir path:
    // e.g. /var/mobile/Containers/Data/Application/<UUID>/tmp → <UUID>/Documents
    final tmp = Directory.systemTemp.path;
    final container =
        tmp.endsWith('/tmp') ? tmp.substring(0, tmp.length - 4) : Directory.systemTemp.parent.path;
    base = '$container/Documents';
  } else {
    base = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
  }
  final dir = Directory('$base/.ssterm');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
