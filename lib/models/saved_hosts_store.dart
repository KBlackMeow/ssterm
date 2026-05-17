import 'dart:convert';
import 'dart:io';

import '../services/credential_crypto.dart';
import 'port_forward_rule.dart';
import 'ssh_host.dart';

class SavedHostsStore {
  static Future<File> _file() async {
    final home = Platform.environment['HOME'] ?? '';
    final dir = Directory('$home/.ssterm');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/hosts.json');
  }

  static Future<List<SshHost>> load() async {
    final f = await _file();
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      final hosts = <SshHost>[];
      var needsMigration = false;
      for (final item in list) {
        final json = item as Map<String, dynamic>;
        hosts.add(await _hostFromStorage(json));
        if (json.containsKey('password')) needsMigration = true;
      }
      if (needsMigration) {
        try {
          await save(hosts);
        } catch (_) {}
      }
      return hosts;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<SshHost> hosts) async {
    final f = await _file();
    final data = <Map<String, dynamic>>[];
    for (final h in hosts) {
      data.add(await _hostToStorage(h));
    }
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  static Future<void> upsert(SshHost host) async {
    final hosts = await load();
    hosts.removeWhere((h) => h.profileKey == host.profileKey);
    hosts.add(host);
    await save(hosts);
  }

  static Future<SshHost> _hostFromStorage(Map<String, dynamic> json) async {
    String? password;
    if (json['passwordEnc'] is String) {
      password = await CredentialCrypto.decrypt(json['passwordEnc'] as String);
    } else if (json['password'] is String) {
      password = json['password'] as String;
    }

    SshHost? jumpHost;
    if (json['jumpHost'] is Map<String, dynamic>) {
      jumpHost = await _hostFromStorage(json['jumpHost'] as Map<String, dynamic>);
    }

    return SshHost(
      alias: json['alias'] as String,
      hostname: json['hostname'] as String,
      port: json['port'] as int? ?? 22,
      user: json['user'] as String?,
      identityFile: json['identityFile'] as String?,
      password: password,
      forwardRules: PortForwardRule.listFromJson(json['forwardRules']),
      jumpHost: jumpHost,
      keepaliveInterval: json['keepaliveInterval'] as int? ?? 0,
      autoReconnect: json['autoReconnect'] as bool? ?? false,
      sessionLog: json['sessionLog'] as bool? ?? false,
    );
  }

  static Future<Map<String, dynamic>> _hostToStorage(SshHost host) async {
    final map = <String, dynamic>{
      'alias': host.alias,
      'hostname': host.hostname,
      'port': host.port,
      if (host.user != null) 'user': host.user,
      if (host.identityFile != null) 'identityFile': host.identityFile,
      if (host.forwardRules.isNotEmpty)
        'forwardRules': PortForwardRule.listToJson(host.forwardRules),
      if (host.keepaliveInterval != 0)
        'keepaliveInterval': host.keepaliveInterval,
      if (host.autoReconnect) 'autoReconnect': host.autoReconnect,
      if (host.sessionLog) 'sessionLog': host.sessionLog,
    };

    if (host.jumpHost != null) {
      map['jumpHost'] = await _hostToStorage(host.jumpHost!);
    }

    if (host.password != null && host.password!.isNotEmpty) {
      map['passwordEnc'] = await CredentialCrypto.encrypt(host.password!);
    }
    return map;
  }
}
