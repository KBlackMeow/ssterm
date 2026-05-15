import 'dart:io';

class SshHost {
  final String alias;
  final String hostname;
  final int port;
  final String? user;
  final String? identityFile;
  final String? password;

  const SshHost({
    required this.alias,
    required this.hostname,
    this.port = 22,
    this.user,
    this.identityFile,
    this.password,
  });

  String get displayInfo {
    final u = user ?? defaultUsername;
    return '$u@$hostname${port != 22 ? ':$port' : ''}';
  }

  static String get defaultUsername =>
      Platform.environment['USER'] ?? 'root';

  /// Stable id for the same server profile (ignores auth method).
  String get profileKey =>
      '$hostname:$port:${user ?? defaultUsername}';

  String get connectionKey {
    final auth = usesPassword ? 'password' : 'key';
    return '$profileKey:${identityFile ?? ''}:$auth';
  }

  bool get usesPassword => password != null && password!.isNotEmpty;

  bool get usesIdentityFile =>
      identityFile != null && identityFile!.isNotEmpty;
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
