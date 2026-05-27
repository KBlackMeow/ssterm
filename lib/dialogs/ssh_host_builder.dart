import '../models/port_forward_rule.dart';
import '../models/ssh_host.dart';

enum SshAuthMode { password, key }

sealed class SshHostFormResult {}

class SshHostFormError extends SshHostFormResult {
  SshHostFormError(this.message);
  final String message;
}

class SshHostFormSuccess extends SshHostFormResult {
  SshHostFormSuccess(this.host);
  final SshHost host;
}

SshHostFormResult buildSshHostResult({
  required String hostText,
  required String userText,
  required String portText,
  required String aliasText,
  required SshAuthMode authMode,
  required String passwordText,
  required String? existingPassword,
  required String keyText,
  required List<PortForwardRule> forwardRules,
  required SshHost? jumpHost,
  required int keepaliveInterval,
  required bool autoReconnect,
  required bool sessionLog,
}) {
  final host = hostText.trim();
  final user = userText.trim();
  final port = int.tryParse(portText.trim()) ?? 22;

  if (host.isEmpty) return SshHostFormError('Enter IP or hostname');
  if (user.isEmpty) return SshHostFormError('Username is required');
  if (port < 1 || port > 65535) return SshHostFormError('Invalid port (1–65535)');

  final alias = aliasText.trim();
  final autoAlias = '$user@$host${port != 22 ? ":$port" : ""}';

  return SshHostFormSuccess(
    SshHost(
      alias: alias.isEmpty ? autoAlias : alias,
      hostname: host,
      port: port,
      user: user,
      password: authMode == SshAuthMode.password
          ? (passwordText.isNotEmpty ? passwordText : existingPassword)
          : null,
      identityFile: authMode == SshAuthMode.key
          ? (keyText.trim().isEmpty ? null : keyText.trim())
          : null,
      forwardRules: List.of(forwardRules),
      jumpHost: jumpHost,
      keepaliveInterval: keepaliveInterval,
      autoReconnect: autoReconnect,
      sessionLog: sessionLog,
    ),
  );
}
