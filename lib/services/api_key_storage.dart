import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API key storage backed by a permission-restricted file at
/// `~/.ssterm/api_keys.json`.  Also attempts keychain I/O as a bonus
/// (works on signed macOS builds and other OS-native keychains).
class ApiKeyStorage {
  static final _storage = FlutterSecureStorage();
  static const _prefix = 'ssterm.api.';
  static Map<String, String>? _cache;

  static Future<File> get _file async {
    final base = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final dir = Directory('$base/.ssterm');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      // Restrict the directory itself so an accidental file with default
      // umask still isn't world-readable through directory listing.
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['700', dir.path]);
        } catch (_) {}
      }
    }
    return File('${dir.path}/api_keys.json');
  }

  static Future<void> _loadCache() async {
    if (_cache != null) return;
    try {
      final f = await _file;
      if (await f.exists()) {
        final raw = await f.readAsString();
        _cache = (jsonDecode(raw) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v as String));
        return;
      }
    } catch (_) {}
    _cache = {};
  }

  static Future<void> _persist() async {
    if (_cache == null) return;
    try {
      final f = await _file;
      // Create the file with 0600 BEFORE any plaintext bytes touch disk.
      // Previously we wrote first and chmod'd second — during that window
      // (and forever, if we crashed mid-write) the file existed under the
      // process's umask, typically 0644 = world-readable.  On Windows
      // there's no chmod equivalent; the file goes into a per-user
      // %USERPROFILE%\.ssterm folder which already has restrictive ACLs.
      if (!Platform.isWindows) {
        if (!await f.exists()) {
          await f.create(recursive: true);
        }
        try {
          await Process.run('chmod', ['600', f.path]);
        } catch (_) {}
      }
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_cache),
      );
      // Re-assert mode after the write — `writeAsString` has been observed
      // to recreate the file on some platforms which can drop perms.
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['600', f.path]);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> store(String providerId, String key) async {
    // Keychain (best-effort).
    try {
      await _storage.write(key: '$_prefix$providerId', value: key);
    } catch (_) {}
    // File (always works).
    await _loadCache();
    _cache![providerId] = key;
    await _persist();
  }

  static Future<String?> load(String providerId) async {
    // Keychain first.
    try {
      final v = await _storage.read(key: '$_prefix$providerId');
      if (v != null) return v;
    } catch (_) {}
    // File fallback.
    await _loadCache();
    return _cache![providerId];
  }

  static Future<void> delete(String providerId) async {
    try {
      await _storage.delete(key: '$_prefix$providerId');
    } catch (_) {}
    await _loadCache();
    _cache!.remove(providerId);
    await _persist();
  }
}
