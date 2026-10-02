/// 将连接表单中的原始字符串转换为 `SshHost`。端口、
/// 必填字段和认证信息在此处统一校验，失败时返回可展示的错误，
/// 不抛出表单校验异常。

import '../models/port_forward_rule.dart';
import '../models/ssh_host.dart';

/// 表单当前使用的认证方式；密码认证和私钥认证采用不同的凭据字段。
enum SshAuthMode { password, key }

/// `buildSshHostResult` 的封闭结果类型，调用方应按成功或失败分支处理，
/// 不需要用异常表示用户输入错误。
sealed class SshHostFormResult {}

/// 表单校验失败结果。`message` 是面向用户的原因，表单可据此提示，
/// 而无需解析底层异常。
class SshHostFormError extends SshHostFormResult {
  SshHostFormError(this.message);
  final String message;
}

/// 表单校验成功结果。`host` 包含规范化后的连接字段及跳板机、转发和重连选项。
class SshHostFormSuccess extends SshHostFormResult {
  SshHostFormSuccess(this.host);
  final SshHost host;
}

/// 规范化并校验主机、用户名、端口、认证凭据和可选 SSH 功能，
/// 再构造 `SshHost`。无效输入通过 `SshHostFormError` 返回，
/// 调用方负责把错误显示在表单中。
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
  if (port < 1 || port > 65535)
    return SshHostFormError('Invalid port (1–65535)');

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
