import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/app_dir.dart';

/// Stores wallpaper images under `<app data>/.ssterm/wallpapers/`.
class WallpaperStorage {
  static Future<Directory> directory() async {
    final dir = Directory(p.join(appBasePath(), '.ssterm', 'wallpapers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static File? resolveFile(String? wallpaperId) {
    if (wallpaperId == null || wallpaperId.isEmpty) return null;
    final file = File(p.join(appBasePath(), '.ssterm', 'wallpapers', wallpaperId));
    return file.existsSync() ? file : null;
  }

  /// Copies [sourcePath] into the wallpapers directory. Returns the stored filename.
  static Future<String?> importFrom(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) return null;

    final dir = await directory();
    final ext = p.extension(sourcePath).toLowerCase();
    final safeExt = _allowedExtensions.contains(ext) ? ext : '.png';
    final name = '${DateTime.now().millisecondsSinceEpoch}$safeExt';
    await source.copy(p.join(dir.path, name));
    return name;
  }

  static Future<void> delete(String wallpaperId) async {
    final file = resolveFile(wallpaperId);
    if (file != null) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static const _allowedExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };
}
