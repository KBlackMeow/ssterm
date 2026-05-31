import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

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
      return _loadFromAsset();
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

  static Future<List<Command>> _loadFromAsset() async {
    try {
      final raw = await rootBundle.loadString('assets/scripts/cmd.json');
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) {
        final json = Map<String, dynamic>.from(e as Map);
        json['builtIn'] = true;
        return Command.fromJson(json);
      }).toList();
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
