import 'dart:convert';
import 'dart:io';

import '../services/credential_crypto.dart';
import 'ssh_host.dart';

/// Recently connected SSH profiles at `~/.ssterm/hosts.json`.
///
/// Stores host, port, username, optional key path, and password (AES-GCM
/// encrypted; master key in the OS keychain). Used to pre-fill the connect
/// dialog and quick-reconnect from the + menu — not for host key trust
/// (`~/.ssterm/known_hosts.json`).
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
        } catch (_) {
          // Still return loaded hosts even if encrypt/migrate fails.
        }
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

    return SshHost(
      alias: json['alias'] as String,
      hostname: json['hostname'] as String,
      port: json['port'] as int? ?? 22,
      user: json['user'] as String?,
      identityFile: json['identityFile'] as String?,
      password: password,
    );
  }

  static Future<Map<String, dynamic>> _hostToStorage(SshHost host) async {
    final map = <String, dynamic>{
      'alias': host.alias,
      'hostname': host.hostname,
      'port': host.port,
      if (host.user != null) 'user': host.user,
      if (host.identityFile != null) 'identityFile': host.identityFile,
    };
    if (host.password != null && host.password!.isNotEmpty) {
      try {
        map['passwordEnc'] =
            await CredentialCrypto.encrypt(host.password!);
      } catch (_) {
        // Keychain/encrypt unavailable — profile is still saved without password.
      }
    }
    return map;
  }
}
