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
    description: json['description'] as String,
    command: json['command'] as String,
  );
}
