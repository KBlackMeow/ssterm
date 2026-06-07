import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';

import '../services/local_shell_discovery.dart';
import '../views/ssh_session_view.dart';
import 'agent_config.dart';
import 'terminal_settings.dart';

class AppConfig {
  AppConfig({
    TerminalSettings? terminal,
    SftpPanelPosition? sftpPosition,
    this.sftpSize,
    List<LocalShellOption>? cachedShells,
    this.agent,
  })  : terminal = terminal ?? TerminalSettings(),
        sftpPosition = sftpPosition ?? SftpPanelPosition.bottom,
        cachedShells = cachedShells ?? const <LocalShellOption>[];

  TerminalSettings terminal;
  SftpPanelPosition sftpPosition;
  double? sftpSize;
  List<LocalShellOption> cachedShells;
  AgentConfig? agent;

  static Future<File> _file() async {
    final dir = await appDataDir();
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
        cachedShells: _decodeShells(json['cachedShells']),
        agent: AgentConfig.fromJson(json['agent'] as Map<String, dynamic>?),
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
        if (cachedShells.isNotEmpty)
          'cachedShells': cachedShells.map((s) => s.toJson()).toList(),
        if (agent != null) 'agent': agent!.toJson(),
      }),
    );
  }

  static List<LocalShellOption> _decodeShells(Object? raw) {
    if (raw is! List) return const [];
    final out = <LocalShellOption>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        final shell = LocalShellOption.fromJson(item);
        if (shell != null) out.add(shell);
      }
    }
    return out;
  }
}
