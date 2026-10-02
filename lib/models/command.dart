/// 命令选择器的一项数据，包含显示名称、说明文本和实际插入终端的命令字符串。
/// JSON 转换用于用户命令列表的持久化。

class Command {
  /// 命令选择器中显示的短名称。
  final String name;
  /// 对命令用途的补充说明，不会被发送到 Shell。
  final String description;
  /// 选择该条目时插入终端的原始命令文本。
  final String command;
  const Command({
    required this.name,
    required this.description,
    required this.command,
  });

  /// 从命令存储中的 JSON 对象构造命令条目。
  factory Command.fromJson(Map<String, dynamic> json) => Command(
    name: json['name'] as String,
    description: (json['description'] as String?) ?? '',
    command: json['command'] as String,
  );

  /// 转成可写入命令列表 JSON 文件的映射。
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'command': command,
  };

  /// 保留未指定字段并返回一份新的不可变命令对象。
  Command copyWith({String? name, String? description, String? command}) =>
      Command(
        name: name ?? this.name,
        description: description ?? this.description,
        command: command ?? this.command,
      );
}
