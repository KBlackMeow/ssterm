import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/widgets/ai_assistant_panel.dart';

void main() {
  testWidgets('populated agent transcript is inside a selection area', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiAssistantOverlay(
            visible: true,
            initialPosition: AiPanelPosition.bottom,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'copy me');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(find.text('copy me'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(ListView),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );
  });
}
