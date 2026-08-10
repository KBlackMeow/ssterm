import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/app_config.dart';
import 'package:ssterm/widgets/ai_assistant_panel.dart';

void main() {
  test('promotes legacy Agent2 layout to Agent layout', () {
    final config = AppConfig.fromJson({
      'agent2Position': 'right',
      'agent2Size': 420,
      'aiPosition': 'bottom',
      'aiSize': 300,
    });

    expect(config.agentPosition, AiPanelPosition.right);
    expect(config.agentSize, 420);
    expect(config.toJson(), containsPair('agentPosition', 'right'));
    expect(config.toJson().containsKey('agent2Position'), isFalse);
    expect(config.toJson().containsKey('aiPosition'), isFalse);
  });

  test('falls back to legacy Agent1 layout when Agent2 is absent', () {
    final config = AppConfig.fromJson({'aiPosition': 'bottom', 'aiSize': 300});

    expect(config.agentPosition, AiPanelPosition.bottom);
    expect(config.agentSize, 300);
  });
}
