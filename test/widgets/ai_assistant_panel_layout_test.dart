import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/widgets/ai_assistant_panel.dart';

void main() {
  testWidgets('Agent panel docks beside its terminal child', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<Size> pumpPanel(bool visible) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiAssistantOverlay(
              visible: visible,
              initialPosition: AiPanelPosition.right,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const ValueKey('terminal-child')));
    }

    final hiddenSize = await pumpPanel(false);
    final shownSize = await pumpPanel(true);

    expect(shownSize.width, lessThan(hiddenSize.width));
    expect(shownSize.height, hiddenSize.height);
  });
}
