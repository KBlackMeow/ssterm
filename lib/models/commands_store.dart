import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';
import 'command.dart';

class CommandsStore {
  static Future<File> _file() async {
    final dir = await appDataDir();
    return File('${dir.path}/commands.json');
  }

  static Future<List<Command>> load() async {
    final f = await _file();
    if (!await f.exists()) {
      return [];
    }
    try {
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      return list
          .map((e) => Command.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<Command> commands) async {
    final f = await _file();
    await f.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(commands.map((c) => c.toJson()).toList()),
    );
  }
}
