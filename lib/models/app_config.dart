import 'dart:convert';
import 'dart:io';

import 'terminal_settings.dart';

enum SftpPanelPosition { right, bottom }

class AppConfig {
  AppConfig({
    this.sftpPanelPosition = SftpPanelPosition.right,
    TerminalSettings? terminal,
  }) : terminal = terminal ?? TerminalSettings();

  SftpPanelPosition sftpPanelPosition;
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
      final pos = json['sftpPanelPosition'];
      return AppConfig(
        sftpPanelPosition: pos == 'bottom'
            ? SftpPanelPosition.bottom
            : SftpPanelPosition.right,
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
        'sftpPanelPosition':
            sftpPanelPosition == SftpPanelPosition.bottom ? 'bottom' : 'right',
        'terminal': terminal.toJson(),
      }),
    );
  }
}
