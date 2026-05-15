import 'dart:io';

import 'package:path/path.dart' as p;

/// Stores wallpaper images under `~/.ssterm/wallpapers/`.
class WallpaperStorage {
  static Future<Directory> directory() async {
    final home = Platform.environment['HOME'] ?? '';
    final dir = Directory(p.join(home, '.ssterm', 'wallpapers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static File? resolveFile(String? wallpaperId) {
    if (wallpaperId == null || wallpaperId.isEmpty) return null;
    final home = Platform.environment['HOME'] ?? '';
    final file = File(p.join(home, '.ssterm', 'wallpapers', wallpaperId));
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
