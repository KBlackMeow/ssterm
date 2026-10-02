/// 按优先级合并模型给出的风险和主机侧安全规则，产出最终等级及命中来源。
/// 主机规则可提升风险，不能把危险命令降级。

import '../models/agent_config.dart';
import 'command_safety.dart';

/// 命令执行策略使用的严重级别：普通命令可按模式自动运行，
/// 警告和危险等级可能要求用户确认。
enum CommandRiskLevel { normal, warning, dangerous }

/// 说明最终等级来自模型判断、主机回退规则、主机覆盖规则，
/// 还是缺少模型判断时的安全回退。
enum CommandRiskSource { ai, hostFallback, hostOverride, missingAiFallback }

/// 一次风险评估的完整结果，包含生效等级、说明、模型与主机等级，
/// 以及命中的主机规则标识，供审批逻辑和结果卡片共用。
class CommandRiskAssessment {
  final CommandRiskLevel level;
  final String reason;
  final CommandRiskLevel? aiLevel;
  final CommandRiskLevel hostLevel;
  final CommandRiskSource source;
  final String? hostPatternId;
  final DangerRuleSource? hostRuleSource;

  const CommandRiskAssessment({
    required this.level,
    required this.reason,
    required this.aiLevel,
    required this.hostLevel,
    required this.source,
    this.hostPatternId,
    this.hostRuleSource,
  });
}

class _WarningRule {
  final String reason;
  final RegExp pattern;
  _WarningRule(this.reason, String pattern)
    : pattern = RegExp(pattern, caseSensitive: false);
}

/// 对模型风险判断应用主机级规则和缺省策略。保留风险来源便于 UI
/// 解释为何某条命令被要求确认。
class CommandRisk {
  static const _mandatoryDangerRules = {
    'rm-rf-root',
    'rm-rf-home',
    'dd-block-device',
    'mkfs',
    'fork-bomb',
    'redirect-to-block-device',
    'shutdown-or-reboot',
    'git-reset-hard',
    'git-clean-force',
  };

  static bool isMandatoryDangerRule(String id) =>
      _mandatoryDangerRules.contains(id);

  static final _warningRules = <_WarningRule>[
    _WarningRule('Deletes files or directories', r'\brm\b'),
    _WarningRule(
      'Changes Git repository state',
      r'\bgit\s+(?:commit|checkout|switch|reset|restore|revert)\b',
    ),
    _WarningRule(
      'Installs or removes software',
      r'\b(?:apt(?:-get)?|brew|dnf|yum|pacman|pip\d*|npm|pnpm|yarn)\s+(?:install|add|remove|uninstall|upgrade|update)\b',
    ),
    _WarningRule(
      'Changes file permissions or ownership',
      r'\b(?:chmod|chown|chgrp)\b',
    ),
    _WarningRule(
      'Changes service state',
      r'\b(?:systemctl|service)\s+(?:start|stop|restart|reload|enable|disable)\b',
    ),
    _WarningRule('Terminates a process', r'\b(?:kill|pkill|killall)\b'),
    _WarningRule(
      'Deletes a container or cluster resource',
      r'\b(?:docker\s+(?:rm|rmi)|kubectl\s+delete)\b',
    ),
  ];

  static CommandRiskAssessment assess({
    required String command,
    required String? aiLevel,
    required String? aiReason,
    required DangerousCommandsPolicy policy,
  }) {
    final parsedAi = _parse(aiLevel);
    final allBuiltins = CommandSafety.builtinDangerRules
        .map((rule) => rule.id)
        .toSet();
    final effectivePolicy = policy.agentConfirmEnabled
        ? policy.copyWith(
            disabledBuiltins: policy.disabledBuiltins.difference(
              _mandatoryDangerRules,
            ),
          )
        : policy.copyWith(
            disabledBuiltins: allBuiltins.difference(_mandatoryDangerRules),
            customPatterns: const [],
          );
    final danger = CommandSafety.danger(
      _canonicalizeMandatorySyntax(command),
      effectivePolicy,
    );
    var hostLevel = CommandRiskLevel.normal;
    var hostReason = 'No host risk rule matched';
    if (danger != null) {
      hostLevel = CommandRiskLevel.dangerous;
      hostReason = danger.label;
    } else {
      for (final raw in command.split('\n')) {
        for (final rule in _warningRules) {
          if (rule.pattern.hasMatch(raw)) {
            hostLevel = CommandRiskLevel.warning;
            hostReason = rule.reason;
            break;
          }
        }
        if (hostLevel == CommandRiskLevel.warning) break;
      }
    }

    if (parsedAi == null) {
      final level = _max(CommandRiskLevel.warning, hostLevel);
      return CommandRiskAssessment(
        level: level,
        reason: hostLevel.index > CommandRiskLevel.warning.index
            ? hostReason
            : 'AI risk classification was missing or invalid',
        aiLevel: null,
        hostLevel: hostLevel,
        source: CommandRiskSource.missingAiFallback,
        hostPatternId: danger?.patternId,
        hostRuleSource: danger?.source,
      );
    }

    if (hostLevel.index > parsedAi.index) {
      return CommandRiskAssessment(
        level: hostLevel,
        reason: hostReason,
        aiLevel: parsedAi,
        hostLevel: hostLevel,
        source: CommandRiskSource.hostOverride,
        hostPatternId: danger?.patternId,
        hostRuleSource: danger?.source,
      );
    }
    return CommandRiskAssessment(
      level: parsedAi,
      reason: aiReason?.trim().isNotEmpty == true
          ? aiReason!.trim()
          : 'Classified by AI as ${parsedAi.name}',
      aiLevel: parsedAi,
      hostLevel: hostLevel,
      source: hostLevel == parsedAi && hostLevel != CommandRiskLevel.normal
          ? CommandRiskSource.hostFallback
          : CommandRiskSource.ai,
      hostPatternId: danger?.patternId,
      hostRuleSource: danger?.source,
    );
  }

  static bool needsConfirmation(
    CommandRiskLevel level, {
    required bool autoExecute,
  }) =>
      level == CommandRiskLevel.dangerous ||
      (!autoExecute && level == CommandRiskLevel.warning);

  static CommandRiskLevel? _parse(String? value) {
    return switch (value) {
      'normal' => CommandRiskLevel.normal,
      'warning' => CommandRiskLevel.warning,
      'dangerous' => CommandRiskLevel.dangerous,
      _ => null,
    };
  }

  static String _canonicalizeMandatorySyntax(String command) => command
      .replaceAll(RegExp(r'\\\r?\n'), ' ')
      .replaceAll('"/"', '/')
      .replaceAll("'/'", '/')
      .replaceAll(r'"$HOME"', r'$HOME')
      .replaceAll(r''' '$HOME' ''', r' $HOME ')
      .replaceAll(r'${HOME}', r'$HOME')
      .replaceAllMapped(
        RegExp(r'\bgit\s+(?:-C\s+\S+\s+)+(?=reset\b)', caseSensitive: false),
        (_) => 'git ',
      );

  static CommandRiskLevel _max(CommandRiskLevel a, CommandRiskLevel b) =>
      a.index >= b.index ? a : b;
}
