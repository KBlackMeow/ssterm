enum ForwardType { local, remote, dynamic_ }

class PortForwardRule {
  final ForwardType type;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final bool enabled;

  const PortForwardRule({
    required this.type,
    required this.localPort,
    this.remoteHost = '',
    this.remotePort = 0,
    this.enabled = true,
  });

  String get label {
    return switch (type) {
      ForwardType.local =>
        'L $localPort → $remoteHost:$remotePort',
      ForwardType.remote =>
        'R $remotePort → localhost:$localPort',
      ForwardType.dynamic_ =>
        'D $localPort (SOCKS5)',
    };
  }

  PortForwardRule copyWith({
    ForwardType? type,
    int? localPort,
    String? remoteHost,
    int? remotePort,
    bool? enabled,
  }) =>
      PortForwardRule(
        type: type ?? this.type,
        localPort: localPort ?? this.localPort,
        remoteHost: remoteHost ?? this.remoteHost,
        remotePort: remotePort ?? this.remotePort,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'type': _typeToString(type),
        'localPort': localPort,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'enabled': enabled,
      };

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
