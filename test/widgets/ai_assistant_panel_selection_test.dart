import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/widgets/ai_assistant_panel.dart';

void main() {
  test(
    'agent loop bounds model and shell work with a visible terminal event',
    () {
      final source = File(
        'lib/widgets/ai_assistant_panel_loop.dart',
      ).readAsStringSync();

      expect(source, contains('final budget = AgentExecutionBudget();'));
      expect(source, contains('budget.consumeModelRequest(DateTime.now())'));
      expect(source, contains('budget.consumeShellCall(DateTime.now())'));
      expect(source, contains('[Agent run stopped]'));
    },
  );

  test('new input records an interruption before cancelling a busy agent', () {
    final source = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();

    expect(source, contains('[Agent run interrupted]'));
    expect(
      source.indexOf('_recordAgentRunInterrupted();'),
      lessThan(source.indexOf('if (_agentBusy) _cancelAgent();')),
    );
  });

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

  testWidgets(
    'follows new agent content after the user returns to the bottom',
    (tester) async {
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

      Future<void> sendHelp() async {
        await tester.enterText(find.byType(TextField), '/help');
        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pumpAndSettle();
      }

      // Fill the transcript until it overflows the compact bottom panel.
      await sendHelp();
      await sendHelp();
      await sendHelp();

      final list = tester.widget<ListView>(find.byType(ListView));
      final position = list.controller!.position;
      expect(position.maxScrollExtent, greaterThan(0));

      // This models the reported path: inspect earlier output, then scroll back
      // to the latest item before the agent produces more output.
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();

      await sendHelp();

      expect(position.pixels, closeTo(position.maxScrollExtent, 0.1));
    },
  );

  testWidgets(
    'does not pull the transcript down while the user reads history',
    (tester) async {
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

      Future<void> sendHelp() async {
        await tester.enterText(find.byType(TextField), '/help');
        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pumpAndSettle();
      }

      await sendHelp();
      await sendHelp();
      await sendHelp();

      final position = tester
          .widget<ListView>(find.byType(ListView))
          .controller!
          .position;
      position.jumpTo(position.minScrollExtent);
      await tester.pump();

      await sendHelp();

      expect(position.pixels, position.minScrollExtent);
    },
  );
}
