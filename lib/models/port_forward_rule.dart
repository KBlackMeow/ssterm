/// 表示一种 SSH 转发规则的类型。本地转发由本机监听，远程转发由 SSH 服务端监听，
/// 动态转发在本机提供 SOCKS5 代理。

enum ForwardType { local, remote, dynamic_ }

/// SSH 主机配置中的一条端口转发规则。字段含义随 `type` 改变；`enabled`
/// 允许保留规则但在连接时跳过，`label` 用于界面展示。
class PortForwardRule {
  /// 转发方向和类型，决定监听端以及其他端口字段的解释方式。
  final ForwardType type;
  /// 转发本地端口：本地/动态转发时为监听端口，远程转发时为 SSH
  /// 服务端连接的本机目标端口。
  final int localPort;
  /// 本地转发的目标主机，由本机发起连接；远程和动态转发不使用此字段。
  final String remoteHost;
  /// 转发目标端口：本地转发时为远端目标端口，远程转发时为 SSH 服务端监听端口；
  /// 动态转发不使用。
  final int remotePort;
  /// 是否在下次 SSH 连接时启用该规则；关闭规则仍保留在配置中。
  final bool enabled;

  const PortForwardRule({
    required this.type,
    required this.localPort,
    this.remoteHost = '',
    this.remotePort = 0,
    this.enabled = true,
  });

  /// 生成面向设置列表的简短规则描述，不用于连接参数解析。
  String get label {
    return switch (type) {
      ForwardType.local => 'L $localPort → $remoteHost:$remotePort',
      ForwardType.remote => 'R $remotePort → localhost:$localPort',
      ForwardType.dynamic_ => 'D $localPort (SOCKS5)',
    };
  }

  /// 更新指定字段并保留其他规则配置。
  PortForwardRule copyWith({
    ForwardType? type,
    int? localPort,
    String? remoteHost,
    int? remotePort,
    bool? enabled,
  }) => PortForwardRule(
    type: type ?? this.type,
    localPort: localPort ?? this.localPort,
    remoteHost: remoteHost ?? this.remoteHost,
    remotePort: remotePort ?? this.remotePort,
    enabled: enabled ?? this.enabled,
  );

  /// 序列化为主机配置中使用的 JSON 字段格式。
  Map<String, dynamic> toJson() => {
    'type': _typeToString(type),
    'localPort': localPort,
    'remoteHost': remoteHost,
    'remotePort': remotePort,
    'enabled': enabled,
  };

  /// 从 JSON 读取规则；未知类型回退为本地转发，缺失端口回退为 0。
  factory PortForwardRule.fromJson(Map<String, dynamic> j) => PortForwardRule(
    type: _typeFromString(j['type'] as String? ?? 'local'),
    localPort: j['localPort'] as int? ?? 0,
    remoteHost: j['remoteHost'] as String? ?? '',
    remotePort: j['remotePort'] as int? ?? 0,
    enabled: j['enabled'] as bool? ?? true,
  );

  static String _typeToString(ForwardType t) => switch (t) {
    ForwardType.local => 'local',
    ForwardType.remote => 'remote',
    ForwardType.dynamic_ => 'dynamic',
  };

  static ForwardType _typeFromString(String s) => switch (s) {
    'remote' => ForwardType.remote,
    'dynamic' => ForwardType.dynamic_,
    _ => ForwardType.local,
  };

  static List<PortForwardRule> listFromJson(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(PortForwardRule.fromJson)
        .toList();
  }

  static List<Map<String, dynamic>> listToJson(List<PortForwardRule> rules) =>
      rules.map((r) => r.toJson()).toList();
}
