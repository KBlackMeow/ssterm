import 'dart:convert';
import 'dart:io';

import '../services/local_shell_discovery.dart';
import '../views/ssh_session_view.dart';
import 'terminal_settings.dart';

class AppConfig {
  AppConfig({
    TerminalSettings? terminal,
    SftpPanelPosition? sftpPosition,
    this.sftpSize,
    this.sftpFrostedGlass = true,
    List<LocalShellOption>? cachedShells,
  })  : terminal = terminal ?? TerminalSettings(),
        sftpPosition = sftpPosition ?? SftpPanelPosition.bottom,
        cachedShells = cachedShells ?? const <LocalShellOption>[];

  TerminalSettings terminal;
  SftpPanelPosition sftpPosition;
  /// Custom panel size in logical pixels; `null` uses [SshSessionView.defaultPanelFraction].
  double? sftpSize;
  /// Blur terminal content behind the SFTP overlay ([BackdropFilter]).
  bool sftpFrostedGlass;

  /// Persisted result of the last local-shell discovery. Restored at startup so
  /// the `+` menu can render synchronously without re-running discovery (which
  /// on Windows involves `wsl --list --quiet` and is the only slow path that
  /// would otherwise delay menu appearance).
  List<LocalShellOption> cachedShells;

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
        sftpFrostedGlass: json['sftpFrostedGlass'] as bool? ?? true,
        cachedShells: _decodeShells(json['cachedShells']),
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
        'sftpFrostedGlass': sftpFrostedGlass,
        if (cachedShells.isNotEmpty)
          'cachedShells': cachedShells.map((s) => s.toJson()).toList(),
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
