import 'dart:io';

/// Returns the base directory under which the app stores its data, safe on all
/// platforms. On Windows `HOME` is unset, so `USERPROFILE` is used instead.
String appBasePath() {
  if (Platform.isIOS) {
    // On iOS, HOME is unset. Derive the app container from the temp dir path:
    // e.g. /var/mobile/Containers/Data/Application/<UUID>/tmp → <UUID>/Documents
    final tmp = Directory.systemTemp.path;
    final container =
        tmp.endsWith('/tmp') ? tmp.substring(0, tmp.length - 4) : Directory.systemTemp.parent.path;
    return '$container/Documents';
  }
  return Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
}

/// Returns the app's writable data directory, safe on all platforms including iOS.
Future<Directory> appDataDir() async {
  final dir = Directory('${appBasePath()}/.ssterm');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
