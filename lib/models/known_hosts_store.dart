import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';
import '../utils/ssh_fingerprint.dart';

/// `known_hosts` 持久化的一条信任记录，由主机名、端口、密钥类型和指纹共同定位。
/// 主机密钥验证器用它区分首次连接、匹配和密钥变更。
class KnownHostEntry {
  /// SSH 握手中报告的主机名；与端口一起作为查找键。
  final String hostname;
  /// SSH 监听端口，默认端口 22 也会显式记录。
  final int port;
  /// 主机公钥算法名称，例如 `ssh-ed25519`。
  final String keyType;
  /// 规范化后的公钥指纹，用于后续连接时比对身份。
  final String fingerprint;

  const KnownHostEntry({
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });

  /// OpenSSH 风格的主机键文本；非默认端口会连同主机名一起编码。
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

/// 将用户确认过的服务器公钥写入 `~/.ssterm/known_hosts.json`，供后续连接校验。
class KnownHostsStore {
  /// 测试专用的数据目录覆盖值；为空时使用应用配置目录，
  /// 避免测试读写用户的真实信任记录。
  static String? debugDirOverride;

  static Future<File> _file() async {
    final dirPath = debugDirOverride ?? (await appDataDir()).path;
    return File('$dirPath/known_hosts.json');
  }

  /// 读取信任文件；文件缺失或 JSON 无法解析时返回空列表。
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

  /// 将完整信任列表写回 JSON 文件。
  static Future<void> save(List<KnownHostEntry> entries) async {
    final f = await _file();
    final data = entries.map((e) => e.toJson()).toList();
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// 按主机名和端口查找信任记录；未找到时返回 `null`。
  static Future<KnownHostEntry?> lookup(String hostname, int port) async {
    final entries = await load();
    for (final e in entries) {
      if (e.hostname == hostname && e.port == port) return e;
    }
    return null;
  }

  /// 信任新指纹并替换该主机端口的旧记录，避免同一目标留下歧义项。
  static Future<void> trust(
    String hostname,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    final entries = await load();
    entries.removeWhere((e) => e.hostname == hostname && e.port == port);
    entries.add(
      KnownHostEntry(
        hostname: hostname,
        port: port,
        keyType: keyType,
        fingerprint: normalizeFingerprint(fingerprint),
      ),
    );
    await save(entries);
  }
}
