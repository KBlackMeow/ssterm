import 'dart:convert';
import 'dart:io';

import '../views/ssh_session_view.dart';
import 'terminal_settings.dart';

class AppConfig {
  AppConfig({TerminalSettings? terminal, SftpPanelPosition? sftpPosition, this.sftpSize})
      : terminal = terminal ?? TerminalSettings(),
        sftpPosition = sftpPosition ?? SftpPanelPosition.bottom;

  TerminalSettings terminal;
  SftpPanelPosition sftpPosition;
  /// Custom panel size in logical pixels; `null` uses [SshSessionView.defaultPanelFraction].
  double? sftpSize;

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
        sftpPosition: json['sftpPosition'] == 'bottom'
            ? SftpPanelPosition.bottom
            : SftpPanelPosition.right,
        sftpSize: (json['sftpSize'] as num?)?.toDouble(),
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
        'sftpPosition': sftpPosition == SftpPanelPosition.bottom ? 'bottom' : 'right',
        if (sftpSize != null) 'sftpSize': sftpSize,
      }),
    );
  }
}
