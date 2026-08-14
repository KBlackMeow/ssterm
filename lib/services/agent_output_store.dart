import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../utils/app_dir.dart';

/// Opaque reference to bounded command output stored locally for one session.
class AgentOutputReference {
  const AgentOutputReference({
    required this.id,
    required this.originalBytes,
    required this.storedBytes,
    required this.truncated,
    required this.preview,
  });

  final String id;
  final int originalBytes;
  final int storedBytes;
  final bool truncated;
  final String preview;
}

/// Bounded output artifacts. The public API accepts only opaque ids, never
/// paths, which keeps the model and UI from reading arbitrary local files.
class AgentOutputStore {
  AgentOutputStore({
    this.directory,
    required this.sessionId,
    this.maxArtifactBytes = 64 * 1024,
    this.maxSessionBytes = 512 * 1024,
    this.maxReadBytes = 8 * 1024,
  }) : assert(maxArtifactBytes > 0),
       assert(maxSessionBytes >= maxArtifactBytes),
       assert(maxReadBytes > 0);

  final Directory? directory;
  final String sessionId;
  final int maxArtifactBytes;
  final int maxSessionBytes;
  final int maxReadBytes;
  int? _storedBytes;

  Future<AgentOutputReference> save(String output) async {
    final bytes = utf8.encode(output);
    final stored = bytes.length > maxArtifactBytes
        ? bytes.sublist(0, maxArtifactBytes)
        : bytes;
    final used = await _currentStoredBytes();
    if (used + stored.length > maxSessionBytes) {
      throw StateError('Agent output artifact session limit reached');
    }
    final root = await _directory();
    await root.create(recursive: true);
    await _restrictPermissions(root.path, '700');
    final id = _newId();
    final target = File('${root.path}/$id.bin');
    await _restrictPermissions(target.path, '600', create: target);
    await target.writeAsBytes(stored, flush: true);
    await _restrictPermissions(target.path, '600');
    _storedBytes = used + stored.length;
    return AgentOutputReference(
      id: id,
      originalBytes: bytes.length,
      storedBytes: stored.length,
      truncated: stored.length < bytes.length,
      preview: _preview(stored),
    );
  }

  Future<String> read(
    String id, {
    required int offset,
    required int maxBytes,
  }) async {
    if (!RegExp(r'^out-[a-f0-9]+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must be an opaque artifact id');
    }
    if (offset < 0 || maxBytes <= 0 || maxBytes > maxReadBytes) {
      throw ArgumentError('Invalid artifact read range');
    }
    final target = File('${(await _directory()).path}/$id.bin');
    if (!await target.exists())
      throw StateError('Agent output artifact missing');
    final bytes = await target.readAsBytes();
    if (offset >= bytes.length) return '';
    final end = min(bytes.length, offset + maxBytes);
    return utf8.decode(bytes.sublist(offset, end), allowMalformed: true);
  }

  /// Removes artifacts belonging to this session without touching unrelated
  /// files in an overridden test or host directory.
  Future<void> clear() async {
    final root = await _directory();
    if (!await root.exists()) return;
    final pattern = RegExp(r'^out-[a-f0-9]+\.bin$');
    await for (final entry in root.list(followLinks: false)) {
      if (entry is File && pattern.hasMatch(entry.uri.pathSegments.last)) {
        await entry.delete();
      }
    }
    _storedBytes = 0;
  }

  Future<int> _currentStoredBytes() async {
    final known = _storedBytes;
    if (known != null) return known;
    final root = await _directory();
    if (!await root.exists()) return _storedBytes = 0;
    var total = 0;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is File &&
          RegExp(r'/out-[a-f0-9]+\.bin$').hasMatch(entry.path)) {
        total += await entry.length();
      }
    }
    return _storedBytes = total;
  }

  Future<Directory> _directory() async {
    final override = directory;
    if (override != null) return override;
    final data = await appDataDir();
    return Directory('${data.path}/agent-output/$sessionId');
  }

  Future<void> _restrictPermissions(
    String path,
    String mode, {
    File? create,
  }) async {
    if (Platform.isWindows) return;
    try {
      if (create != null && !await create.exists()) await create.create();
      await Process.run('chmod', [mode, path]);
    } catch (_) {
      // The app must remain usable on filesystems without POSIX permissions.
    }
  }

  String _newId() {
    final random = Random.secure();
    final suffix = List<int>.generate(
      12,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'out-$suffix';
  }

  String _preview(List<int> bytes) {
    const previewBytes = 2048;
    if (bytes.length <= previewBytes) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    // Leave room for the elision marker so the preview itself stays near the
    // advertised 2 KB token-friendly budget.
    const headBytes = 960;
    const tailBytes = 960;
    return '${utf8.decode(bytes.sublist(0, headBytes), allowMalformed: true)}\n'
        '… [${bytes.length - headBytes - tailBytes} artifact bytes elided] …\n'
        '${utf8.decode(bytes.sublist(bytes.length - tailBytes), allowMalformed: true)}';
  }
}
