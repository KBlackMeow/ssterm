class Command {
  final String name;
  final String description;
  final String command;
  const Command({
    required this.name,
    required this.description,
    required this.command,
  });

  factory Command.fromJson(Map<String, dynamic> json) => Command(
    name: json['name'] as String,
    description: (json['description'] as String?) ?? '',
    command: json['command'] as String,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'command': command,
  };

  Command copyWith({String? name, String? description, String? command}) =>
      Command(
        name: name ?? this.name,
        description: description ?? this.description,
        command: command ?? this.command,
      );
}
