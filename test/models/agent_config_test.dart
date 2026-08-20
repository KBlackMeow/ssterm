import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/agent_decision_policy.dart';

void main() {
  const enabled = AgentDecisionSettings(
    enabled: true,
    firstTurnToolFocus: true,
  );

  test('adaptive decision settings default to disabled per model', () {
    final config = AgentConfig.fromJson({'providers': const []});

    expect(config.decisionSettingsFor('ollama', 'qwen-27b').enabled, isFalse);
  });

  test(
    'adaptive decision settings round trip without affecting other models',
    () {
      final config = AgentConfig();
      config.setDecisionSettings('ollama', 'qwen-27b', enabled);

      final restored = AgentConfig.fromJson(config.toJson());

      expect(
        restored.decisionSettingsFor('ollama', 'qwen-27b').enabled,
        isTrue,
      );
      expect(
        restored.decisionSettingsFor('ollama', 'qwen-27b').firstTurnToolFocus,
        isTrue,
      );
      expect(
        restored.decisionSettingsFor('ollama', 'other-27b').enabled,
        isFalse,
      );
    },
  );
}
