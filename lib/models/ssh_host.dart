import 'dart:io';

import '../utils/app_dir.dart';
import 'port_forward_rule.dart';

/// 一个可保存和复用的 SSH 连接档案，包含目标地址、账号、密码/私钥认证、跳板机、
/// 转发规则和断线重连选项。连接运行时资源不放在此模型中。
class SshHost {
  /// 用户自定义别名；用于标签、保存列表和连接提示。
  final String alias;
  /// 连接目标的 DNS 名称或 IP 地址。
  final String hostname;
  /// SSH 服务端口；未指定时使用标准端口 22。
  final int port;
  /// 登录用户名；为空时回退到当前平台的默认用户名。
  final String? user;
  /// 私钥文件路径；为空时由 SSH 客户端尝试默认身份文件。
  final String? identityFile;
  /// 密码认证凭据。持久化时由凭据存储单独保存，不应明文写入主机 JSON。
  final String? password;

  /// 连接建立后需要启动的本地、远程或动态转发规则。
  final List<PortForwardRule> forwardRules;

  /// 可选跳板主机；目标连接经由此档案建立单跳 ProxyJump。
  final SshHost? jumpHost;

  /// Keepalive 间隔秒数；`0` 表示禁用探测。
  final int keepaliveInterval; // seconds, 0 = disabled
  /// 会话意外断开时是否自动尝试重连。
  final bool autoReconnect;

  /// 是否将本次 SSH 终端会话原始数据写入可回放日志。
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

  static String get defaultUsername => Platform.environment['USER'] ?? 'root';

  String get profileKey => '$hostname:$port:${user ?? defaultUsername}';

  String get connectionKey {
    final auth = usesPassword ? 'password' : 'key';
    return '$profileKey:${identityFile ?? ''}:$auth';
  }

  bool get usesPassword => password != null && password!.isNotEmpty;

  bool get usesIdentityFile => identityFile != null && identityFile!.isNotEmpty;

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
  }) => SshHost(
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

/// 判断输入是否像私钥文件路径，以便连接表单区分路径和直接粘贴的密钥内容。
/// 这里只做格式识别，不检查文件存在性或密钥有效性。
bool looksLikeKeyPath(String value) {
  final t = value.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('~/') || t.startsWith('/')) return true;
  if (t.contains('/')) return true;
  return RegExp(r'\.(pem|key)$', caseSensitive: false).hasMatch(t);
}

/// 将以 `~` 开头的私钥路径替换为应用识别的用户目录路径；其他路径保持原样。
/// 该函数不解析 shell 变量或相对路径。
String expandHomePath(String path) {
  final home = appBasePath();
  if (path.startsWith('~/')) return '$home${path.substring(1)}';
  if (path == '~') return home;
  return path;
}
