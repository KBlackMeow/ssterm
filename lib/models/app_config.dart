/// 应用设置文件的读取与写入入口。界面位置、缓存的 Shell 列表和 Agent
/// 配置由此聚合；缺失或无法读取配置时使用默认值，以保证首次启动可用。

import 'dart:convert';
import 'dart:io';

import '../utils/app_dir.dart';

import '../services/local_shell_discovery.dart';
import '../views/ssh_session_view.dart';
import '../widgets/ai_assistant_panel.dart' show AiPanelPosition;
import 'agent_config.dart';
import 'terminal_settings.dart';

/// 聚合跨页面的用户设置，包括终端外观、SFTP/Agent 面板位置与尺寸、已发现 Shell
/// 缓存和 Agent 配置。静态加载/保存方法负责文件持久化。
class AppConfig {
  AppConfig({
    TerminalSettings? terminal,
    SftpPanelPosition? sftpPosition,
    this.sftpSize,
    AiPanelPosition? agentPosition,
    this.agentSize,
    List<LocalShellOption>? cachedShells,
    this.agent,
  }) : terminal = terminal ?? TerminalSettings(),
       sftpPosition = sftpPosition ?? SftpPanelPosition.bottom,
       agentPosition = agentPosition ?? AiPanelPosition.bottom,
       cachedShells = cachedShells ?? const <LocalShellOption>[];

  /// 终端字体、主题、光标和壁纸等显示设置。
  TerminalSettings terminal;
  /// SFTP 浏览面板相对终端的停靠边；没有配置时默认停靠底部。
  SftpPanelPosition sftpPosition;
  /// SFTP 面板沿停靠方向的尺寸；`null` 表示由布局使用默认尺寸。
  double? sftpSize;
  /// Agent 面板的停靠边；没有配置时默认停靠底部。
  AiPanelPosition agentPosition;
  /// Agent 面板沿停靠方向的尺寸；`null` 表示使用默认尺寸。
  double? agentSize;
  /// 最近发现的本地 Shell 列表缓存，用于快速构建新终端菜单。
  List<LocalShellOption> cachedShells;
  /// Agent、provider、工具和安全策略配置；首次启动时可为空。
  AgentConfig? agent;

  static Future<File> _file() async {
    final dir = await appDataDir();
    return File('${dir.path}/config.json');
  }

  /// 读取应用配置；文件不存在或内容损坏时返回默认配置，保证启动继续进行。
  static Future<AppConfig> load() async {
    final f = await _file();
    if (!await f.exists()) return AppConfig();
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return AppConfig.fromJson(json);
    } catch (_) {
      return AppConfig();
    }
  }

  /// 将持久化字段转换为设置模型，并兼容旧版 Agent 面板字段名。
  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final agentPosition =
        json['agentPosition'] ?? json['agent2Position'] ?? json['aiPosition'];
    final agentSize = json['agentSize'] ?? json['agent2Size'] ?? json['aiSize'];
    return AppConfig(
      terminal: TerminalSettings.fromJson(
        json['terminal'] as Map<String, dynamic>?,
      ),
      sftpPosition: json['sftpPosition'] == 'bottom'
          ? SftpPanelPosition.bottom
          : SftpPanelPosition.right,
      sftpSize: (json['sftpSize'] as num?)?.toDouble(),
      agentPosition: agentPosition == 'right'
          ? AiPanelPosition.right
          : AiPanelPosition.bottom,
      agentSize: (agentSize as num?)?.toDouble(),
      cachedShells: _decodeShells(json['cachedShells']),
      agent: AgentConfig.fromJson(json['agent'] as Map<String, dynamic>?),
    );
  }

  /// 将当前设置序列化并写入应用配置文件。
  Future<void> save() async {
    final f = await _file();
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  Map<String, dynamic> toJson() => {
    'terminal': terminal.toJson(),
    'sftpPosition': sftpPosition == SftpPanelPosition.bottom
        ? 'bottom'
        : 'right',
    if (sftpSize != null) 'sftpSize': sftpSize,
    'agentPosition': agentPosition == AiPanelPosition.bottom
        ? 'bottom'
        : 'right',
    if (agentSize != null) 'agentSize': agentSize,
    if (cachedShells.isNotEmpty)
      'cachedShells': cachedShells.map((s) => s.toJson()).toList(),
    if (agent != null) 'agent': agent!.toJson(),
  };

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
