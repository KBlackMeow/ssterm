import 'dart:convert';
import 'dart:io';

import '../utils/ssh_fingerprint.dart';

class KnownHostEntry {
  final String hostname;
  final int port;
  final String keyType;
  final String fingerprint;

  const KnownHostEntry({
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });

  String get hostKey => port == 22 ? hostname : '[$hostname]:$port';

  Map<String, dynamic> toJson() => {
        'hostname': hostname,
        'port': port,
        'keyType': keyType,
        'fingerprint': fingerprint,
      };

  factory KnownHostEntry.fromJson(Map<String, dynamic> json) => KnownHostEntry(
        hostname: json['hostname'] as String,
        port: json['port'] as int? ?? 22,
        keyType: json['keyType'] as String,
        fingerprint: json['fingerprint'] as String,
      );
}

/// Trusted SSH server host keys (~/.ssterm/known_hosts.json).
class KnownHostsStore {
  static Future<File> _file() async {
    final home = Platform.environment['HOME'] ?? '';
    final dir = Directory('$home/.ssterm');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/known_hosts.json');
  }

  static Future<List<KnownHostEntry>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      return list
          .map((e) => KnownHostEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<KnownHostEntry> entries) async {
    final f = await _file();
    final data = entries.map((e) => e.toJson()).toList();
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  static Future<KnownHostEntry?> lookup(String hostname, int port) async {
    final entries = await load();
    for (final e in entries) {
      if (e.hostname == hostname && e.port == port) return e;
    }
    return null;
  }

  static Future<void> trust(
    String hostname,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    final entries = await load();
    entries.removeWhere((e) => e.hostname == hostname && e.port == port);
    entries.add(KnownHostEntry(
      hostname: hostname,
      port: port,
      keyType: keyType,
      fingerprint: normalizeFingerprint(fingerprint),
    ));
    await save(entries);
  }
}
