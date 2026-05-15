import 'dart:io';

class SshHost {
  final String alias;
  final String hostname;
  final int port;
  final String? user;
  final String? identityFile;

  const SshHost({
    required this.alias,
    required this.hostname,
    this.port = 22,
    this.user,
    this.identityFile,
  });

  String get displayInfo =>
      '${user != null ? '$user@' : ''}$hostname${port != 22 ? ':$port' : ''}';
}

Future<List<SshHost>> parseSshConfig() async {
  final home = Platform.environment['HOME'] ?? '';
  final file = File('$home/.ssh/config');
  if (!await file.exists()) return [];

  final hosts = <SshHost>[];
  String? alias;
  String? hostname;
  int port = 22;
  String? user;
  String? identityFile;

  void flush() {
    final a = alias;
    if (a == null || a.contains('*')) return;
    hosts.add(SshHost(
      alias: a,
      hostname: hostname ?? a,
      port: port,
      user: user,
      identityFile: identityFile,
    ));
  }

  for (final raw in await file.readAsLines()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final match = RegExp(r'^(\S+)[\s=]+(.+)$').firstMatch(line);
    if (match == null) continue;
    final key = match.group(1)!.toLowerCase();
    final val = match.group(2)!.trim();

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
        identityFile = val.replaceAll('~', home);
    }
  }
  flush();
  return hosts;
}
