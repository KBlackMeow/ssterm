import 'dart:io';

import 'port_forward_rule.dart';

class SshHost {
  final String alias;
  final String hostname;
  final int port;
  final String? user;
  final String? identityFile;
  final String? password;

  // Feature 1: port forwarding
  final List<PortForwardRule> forwardRules;

  // Feature 2: jump host
  final SshHost? jumpHost;

  // Feature 4: keepalive + auto-reconnect
  final int keepaliveInterval; // seconds, 0 = disabled
  final bool autoReconnect;

  // Feature 5: session logging
  final bool sessionLog;

  const SshHost({
    required this.alias,
    required this.hostname,
    this.port = 22,
    this.user,
    this.identityFile,
    this.password,
    this.forwardRules = const [],
    this.jumpHost,
    this.keepaliveInterval = 0,
    this.autoReconnect = false,
    this.sessionLog = false,
  });

  String get displayInfo {
    final u = user ?? defaultUsername;
    return '$u@$hostname${port != 22 ? ':$port' : ''}';
  }

  static String get defaultUsername =>
      Platform.environment['USER'] ?? 'root';

  String get profileKey =>
      '$hostname:$port:${user ?? defaultUsername}';

  String get connectionKey {
    final auth = usesPassword ? 'password' : 'key';
    return '$profileKey:${identityFile ?? ''}:$auth';
  }

  bool get usesPassword => password != null && password!.isNotEmpty;

  bool get usesIdentityFile =>
      identityFile != null && identityFile!.isNotEmpty;

  SshHost copyWith({
    String? alias,
    String? hostname,
    int? port,
    String? user,
    String? identityFile,
    String? password,
    List<PortForwardRule>? forwardRules,
    SshHost? jumpHost,
    bool clearJumpHost = false,
    int? keepaliveInterval,
    bool? autoReconnect,
    bool? sessionLog,
  }) =>
      SshHost(
        alias: alias ?? this.alias,
        hostname: hostname ?? this.hostname,
        port: port ?? this.port,
        user: user ?? this.user,
        identityFile: identityFile ?? this.identityFile,
        password: password ?? this.password,
        forwardRules: forwardRules ?? this.forwardRules,
        jumpHost: clearJumpHost ? null : (jumpHost ?? this.jumpHost),
        keepaliveInterval: keepaliveInterval ?? this.keepaliveInterval,
        autoReconnect: autoReconnect ?? this.autoReconnect,
        sessionLog: sessionLog ?? this.sessionLog,
      );
}

bool looksLikeKeyPath(String value) {
  final t = value.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('~/') || t.startsWith('/')) return true;
  if (t.contains('/')) return true;
  return RegExp(r'\.(pem|key)$', caseSensitive: false).hasMatch(t);
}

String expandHomePath(String path) {
  final home = Platform.environment['HOME'] ?? '';
  if (path.startsWith('~/')) return '$home${path.substring(1)}';
  return path.replaceAll('~', home);
}
