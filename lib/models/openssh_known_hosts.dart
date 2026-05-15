import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../utils/ssh_fingerprint.dart';
import 'known_hosts_store.dart';

class _OpenSshKeyLine {
  const _OpenSshKeyLine({
    required this.hostPatterns,
    required this.keyType,
    required this.fingerprint,
  });

  final List<String> hostPatterns;
  final String keyType;
  final String fingerprint;
}

/// Reads OpenSSH `~/.ssh/known_hosts` (plain and hashed `|1|` entries).
class OpenSshKnownHosts {
  static Future<File> file() async {
    final home = Platform.environment['HOME'] ?? '';
    return File('$home/.ssh/known_hosts');
  }

  static Future<List<_OpenSshKeyLine>> _loadLines() async {
    final f = await file();
    if (!await f.exists()) return [];
    final lines = await f.readAsLines();
    final result = <_OpenSshKeyLine>[];
    for (final line in lines) {
      final parsed = _parseLine(line);
      if (parsed != null) result.add(parsed);
    }
    return result;
  }

  static Future<List<KnownHostEntry>> lookup(
    String hostname,
    int port,
    String keyType,
  ) async {
    final all = await _loadLines();
    final entries = <KnownHostEntry>[];
    for (final line in all) {
      if (line.keyType != keyType) continue;
      final matches = line.hostPatterns.any(
        (p) => _hostPatternMatches(p, hostname, port),
      );
      if (!matches) continue;
      entries.add(KnownHostEntry(
        hostname: hostname,
        port: port,
        keyType: keyType,
        fingerprint: line.fingerprint,
      ));
    }
    return entries;
  }

  static _OpenSshKeyLine? _parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    if (trimmed.startsWith('@')) return null;

    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 3) return null;

    final hostsField = parts[0];
    final keyType = parts[1];
    final keyB64 = parts[2];

    Uint8List keyBytes;
    try {
      keyBytes = Uint8List.fromList(base64Decode(_padBase64(keyB64)));
    } catch (_) {
      return null;
    }

    final fingerprint = normalizeFingerprint(
      formatMd5Fingerprint(Uint8List.fromList(md5.convert(keyBytes).bytes)),
    );

    final patterns =
        hostsField.split(',').where((p) => p.isNotEmpty).toList();
    if (patterns.isEmpty) return null;

    return _OpenSshKeyLine(
      hostPatterns: patterns,
      keyType: keyType,
      fingerprint: fingerprint,
    );
  }

  static bool _hostPatternMatches(
    String pattern,
    String hostname,
    int port,
  ) {
    if (pattern.startsWith('|')) {
      return _hashedHostMatches(pattern, hostname, port);
    }

    if (pattern.startsWith('[')) {
      final close = pattern.indexOf(']');
      if (close < 0) return false;
      final host = pattern.substring(1, close);
      final rest = pattern.substring(close + 1);
      if (!rest.startsWith(':')) return false;
      final p = int.tryParse(rest.substring(1));
      if (p == null) return false;
      return host == hostname && p == port;
    }

    if (pattern.contains('*') || pattern.contains('?')) {
      return _wildcardMatch(pattern, hostname);
    }

    return pattern == hostname;
  }

  static bool _hashedHostMatches(String pattern, String hostname, int port) {
    final segments = pattern.split('|');
    if (segments.length < 4 || segments[1] != '1') return false;

    Uint8List salt;
    try {
      salt = Uint8List.fromList(base64Decode(_padBase64(segments[2])));
    } catch (_) {
      return false;
    }
    final expectedHash = segments[3].replaceAll('=', '');

    final candidates = <String>[
      hostname,
      if (port != 22) '[$hostname]:$port',
    ];

    for (final host in candidates) {
      final hmac = Hmac(sha1, salt);
      final digest = hmac.convert(utf8.encode(host));
      final computed = base64Encode(digest.bytes).replaceAll('=', '');
      if (computed == expectedHash) return true;
    }
    return false;
  }

  static bool _wildcardMatch(String pattern, String hostname) {
    if (!pattern.contains('*') && !pattern.contains('?')) {
      return pattern == hostname;
    }
    final re = RegExp(
      '^${RegExp.escape(pattern).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$',
    );
    return re.hasMatch(hostname);
  }

  static String _padBase64(String s) {
    final rem = s.length % 4;
    if (rem == 0) return s;
    return s + '=' * (4 - rem);
  }
}
