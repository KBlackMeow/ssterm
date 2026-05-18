import 'dart:convert';
import 'dart:io';

import 'terminal_settings.dart';

class AppConfig {
  AppConfig({TerminalSettings? terminal})
      : terminal = terminal ?? TerminalSettings();

  TerminalSettings terminal;

  static Future<File> _file() async {
    final home = Platform.environment['HOME'] ?? '';
    final dir = Directory('$home/.ssterm');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/config.json');
  }

  static Future<AppConfig> load() async {
    final f = await _file();
    if (!await f.exists()) return AppConfig();
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return AppConfig(
        terminal: TerminalSettings.fromJson(
          json['terminal'] as Map<String, dynamic>?,
        ),
      );
    } catch (_) {
      return AppConfig();
    }
  }

  Future<void> save() async {
    final f = await _file();
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'terminal': terminal.toJson(),
      }),
    );
  }
}
