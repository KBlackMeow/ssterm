import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/command_risk.dart';

void main() {
  final policy = DangerousCommandsPolicy();

  group('CommandRisk.assess', () {
    test('keeps a valid AI classification', () {
      final value = CommandRisk.assess(
        command: 'pwd',
        aiLevel: 'normal',
        aiReason: 'read only',
        policy: policy,
      );
      expect(value.level, CommandRiskLevel.normal);
      expect(value.source, CommandRiskSource.ai);
      expect(value.reason, 'read only');
    });

    test('treats missing and invalid AI classifications as warning', () {
      for (final level in <String?>[null, '', 'safe']) {
        final value = CommandRisk.assess(
          command: 'pwd',
          aiLevel: level,
          aiReason: null,
          policy: policy,
        );
        expect(value.level, CommandRiskLevel.warning);
        expect(value.source, CommandRiskSource.missingAiFallback);
      }
    });

    test('host dangerous rule upgrades AI normal', () {
      final value = CommandRisk.assess(
        command: 'git reset --hard',
        aiLevel: 'normal',
        aiReason: 'cleanup',
        policy: policy,
      );
      expect(value.level, CommandRiskLevel.dangerous);
      expect(value.aiLevel, CommandRiskLevel.normal);
      expect(value.source, CommandRiskSource.hostOverride);
    });

    test('catastrophic host rules cannot be disabled', () {
      final disabled = DangerousCommandsPolicy(
        disabledBuiltins: {'rm-rf-root', 'git-reset-hard'},
      );
      for (final command in ['rm -rf /', 'git reset --hard']) {
        final value = CommandRisk.assess(
          command: command,
          aiLevel: 'normal',
          aiReason: 'cleanup',
          policy: disabled,
        );
        expect(value.level, CommandRiskLevel.dangerous, reason: command);
      }
    });

    test('host warning rule upgrades AI normal', () {
      final value = CommandRisk.assess(
        command: 'rm -rf node_modules',
        aiLevel: 'normal',
        aiReason: 'cleanup',
        policy: policy,
      );
      expect(value.level, CommandRiskLevel.warning);
      expect(value.source, CommandRiskSource.hostOverride);
    });

    test('multiline command uses the highest host risk', () {
      final value = CommandRisk.assess(
        command: 'pwd\ngit reset --hard',
        aiLevel: 'normal',
        aiReason: 'inspect',
        policy: policy,
      );
      expect(value.level, CommandRiskLevel.dangerous);
    });

    test('never lowers an AI dangerous classification', () {
      final value = CommandRisk.assess(
        command: 'pwd',
        aiLevel: 'dangerous',
        aiReason: 'sensitive context',
        policy: policy,
      );
      expect(value.level, CommandRiskLevel.dangerous);
      expect(value.source, CommandRiskSource.ai);
    });
  });

  test('confirmation matrix matches cautious and auto modes', () {
    expect(
      CommandRisk.needsConfirmation(
        CommandRiskLevel.normal,
        autoExecute: false,
      ),
      isFalse,
    );
    expect(
      CommandRisk.needsConfirmation(
        CommandRiskLevel.warning,
        autoExecute: false,
      ),
      isTrue,
    );
    expect(
      CommandRisk.needsConfirmation(
        CommandRiskLevel.dangerous,
        autoExecute: false,
      ),
      isTrue,
    );
    expect(
      CommandRisk.needsConfirmation(CommandRiskLevel.normal, autoExecute: true),
      isFalse,
    );
    expect(
      CommandRisk.needsConfirmation(
        CommandRiskLevel.warning,
        autoExecute: true,
      ),
      isFalse,
    );
    expect(
      CommandRisk.needsConfirmation(
        CommandRiskLevel.dangerous,
        autoExecute: true,
      ),
      isTrue,
    );
  });
}
