import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/app_config.dart';
import 'package:ssterm/widgets/ai_assistant_panel.dart';

void main() {
  late Directory startupDirectory;
  late File startupFile;

  setUp(() {
    startupDirectory = Directory.systemTemp.createTempSync('ssterm-config-');
    startupFile = File('${startupDirectory.path}/config.json');
  });

  tearDown(() => startupDirectory.deleteSync(recursive: true));

  test(
    'startup snapshot restores settings before returning to the event loop',
    () {
      startupFile.writeAsStringSync(
        '{"terminal":{"fontSize":19},"agentPosition":"right","agentSize":420}',
      );

      final config = AppConfig.loadStartupSnapshot(startupFile);

      expect(config.terminal.fontSize, 19);
      expect(config.agentPosition, AiPanelPosition.right);
      expect(config.agentSize, 420);
    },
  );

  test('missing startup snapshot uses defaults without creating a file', () {
    final config = AppConfig.loadStartupSnapshot(startupFile);

    expect(config.terminal.fontSize, AppConfig().terminal.fontSize);
    expect(startupFile.existsSync(), isFalse);
  });

  test('invalid startup snapshot uses defaults', () {
    for (final content in ['{broken', '[]', '{"terminal":42}']) {
      startupFile.writeAsStringSync(content);
      final config = AppConfig.loadStartupSnapshot(startupFile);
      expect(config.terminal.fontSize, AppConfig().terminal.fontSize);
    }
  });

  test('promotes the newest legacy layout to the Agent layout', () {
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

  test('falls back to the earlier legacy layout', () {
    final config = AppConfig.fromJson({'aiPosition': 'bottom', 'aiSize': 300});

    expect(config.agentPosition, AiPanelPosition.bottom);
    expect(config.agentSize, 300);
  });

  test('does not retain dead pre-Agent layout fields', () {
    final source = File('lib/models/app_config.dart').readAsStringSync();

    expect(source, isNot(contains('AiPanelPosition aiPosition;')));
    expect(source, isNot(contains('double? aiSize;')));
    expect(source, isNot(contains('this.aiSize')));
  });
}
