import 'dart:io';

import '../utils/app_dir.dart';
import 'ssh_host.dart';

/// Parses OpenSSH `~/.ssh/config` (and optional `Include` files).
Future<List<SshHost>> parseSshConfig() async {
  final home = appBasePath();
  final root = File('${userSshDir()}/config');
  if (!await root.exists()) return [];

  final seen = <String>{};
  final hosts = <SshHost>[];
  await _parseFile(root, home, hosts, seen, depth: 0);
  return hosts;
}

Future<void> _parseFile(
  File file,
  String home,
  List<SshHost> hosts,
  Set<String> seen, {
  required int depth,
}) async {
  if (depth > 8 || !await file.exists()) return;
  final canonical = await file.resolveSymbolicLinks();
  if (!seen.add(canonical)) return;

  String? alias;
  String? hostname;
  int port = 22;
  String? user;
  String? identityFile;

  void flush() {
    final a = alias?.trim();
    if (a == null || a.isEmpty) return;
    for (final name in a.split(RegExp(r'\s+'))) {
      if (name.isEmpty || name.contains('*') || name.contains('?')) continue;
      hosts.add(SshHost(
        alias: name,
        hostname: hostname ?? name,
        port: port,
        user: user,
        identityFile:
            identityFile != null ? expandHomePath(identityFile) : null,
      ));
    }
  }

  for (final raw in await file.readAsLines()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final match = RegExp(r'^(\S+)\s+(.+)$').firstMatch(line);
    if (match == null) continue;
    final key = match.group(1)!.toLowerCase();
    var val = match.group(2)!.trim();
    if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
      val = val.substring(1, val.length - 1);
    }

    switch (key) {
      case 'host':
        flush();
        alias = val;
        hostname = null;
        port = 22;
        user = null;
        identityFile = null;
      case 'hostname':
        hostname = val;
      case 'port':
        port = int.tryParse(val) ?? 22;
      case 'user':
        user = val;
      case 'identityfile':
        identityFile = val;
      case 'include':
        for (final pattern in val.split(RegExp(r'\s+'))) {
          if (pattern.isEmpty) continue;
          final paths = await _expandInclude(home, pattern);
          for (final p in paths) {
            await _parseFile(File(p), home, hosts, seen, depth: depth + 1);
          }
        }
    }
  }
  flush();
}

Future<List<String>> _expandInclude(String home, String pattern) async {
  if (pattern.startsWith('~/')) {
    pattern = '$home${pattern.substring(1)}';
  } else if (pattern.startsWith('~')) {
    pattern = expandHomePath(pattern);
  } else if (!pattern.startsWith('/')) {
    pattern = '$home/.ssh/$pattern';
  }

  if (!pattern.contains('*') && !pattern.contains('?')) {
    return [pattern];
  }

  final slash = pattern.lastIndexOf('/');
  if (slash < 0) return [];
  final dir = Directory(pattern.substring(0, slash));
  if (!await dir.exists()) return [];
  final name = pattern.substring(slash + 1);
  final re = RegExp(
    '^${RegExp.escape(name).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$',
  );
  final out = <String>[];
  await for (final entity in dir.list()) {
    if (entity is File && re.hasMatch(entity.uri.pathSegments.last)) {
      out.add(entity.path);
    }
  }
  return out;
}
