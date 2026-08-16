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

  test('new input during a busy agent is queued instead of interrupting', () {
    final source = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();

    expect(source, contains('_pendingUserInput.add(text)'));
    expect(source, contains('void _drainQueuedUserInput()'));
    // The old interrupt-on-send path is gone — input is queued instead of
    // being fed straight through as a replacement instruction.
    expect(source, isNot(contains('_recordAgentRunInterrupted')));
  });

  test('cancelling backfills any dangling native tool call', () {
    final source = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();

    expect(source, contains('void _completeInterruptedToolCalls()'));
    expect(source, contains("content: '[Tool interrupted by user]'"));
    expect(source, contains('isError: true'));
    expect(source, contains('_completeInterruptedToolCalls();'));
  });

  test('clearing the chat drops queued input before cancelling', () {
    final source = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();

    // `_clearChat` must empty the queue (and null the proposal pause
    // signals) BEFORE `_cancelAgent` runs, otherwise the cancel's tail
    // drain would resurrect a queued message on the freshly cleared chat.
    final clearQueue = source.indexOf(
      '_pendingUserInput.clear();\n    _pendingWriteProposal = null;',
    );
    final cancel = source.indexOf('if (_agentBusy) _cancelAgent();');
    expect(clearQueue, isNot(-1));
    expect(cancel, isNot(-1));
    expect(clearQueue, lessThan(cancel));
  });

  test('cancelling marks a running command card stopped', () {
    final source = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();

    // A command card whose execution was aborted must not stay frozen at
    // "运行中" — the cancel path flips it to a terminal state because the
    // loop's post-execute `commandRunning = false` is skipped on cancel.
    expect(source, contains('message.isSystem && message.commandRunning == true'));
    expect(source, contains('message.commandRunning = false'));
    expect(source, contains('message.commandExitCode = null'));
  });

  test('cancelling flips an in-flight danger card to stopped', () {
    final source = File(
      'lib/widgets/ai_assistant_panel.dart',
    ).readAsStringSync();

    // An approved-but-still-executing danger card must not stay at
    // "RUNNING…" after a stop — it flips to a muted "STOPPED" badge.
    expect(source, contains('danger.state == _DangerProposalState.running'));
    expect(source, contains('danger.state = _DangerProposalState.stopped'));
  });

  test('write/edit decisions hold the pause signal across the commit', () {
    final source = File(
      'lib/widgets/ai_assistant_panel_tooling.dart',
    ).readAsStringSync();

    // The proposal pause field must stay set through the `adapter.commit`
    // await (so mid-commit input queues instead of racing the resume), and
    // only drop once the decision fully resolves.
    expect(source, contains("keep `_agentEngaged` true across the commit"));
    final commit = source.indexOf('await adapter.commit(');
    final lastWriteClear = source.lastIndexOf('_pendingWriteProposal = null;');
    final lastEditClear = source.lastIndexOf('_pendingEditProposal = null;');
    expect(commit, isNot(-1));
    expect(lastWriteClear, greaterThan(commit));
    expect(lastEditClear, greaterThan(commit));
  });

  test(
    'command feedback references bounded output artifacts when available',
    () {
      final source = File(
        'lib/widgets/ai_assistant_panel_loop.dart',
      ).readAsStringSync();

      expect(source, contains('_outputStore.save(result.output)'));
      expect(source, contains('artifact: outputArtifact'));
    },
  );

  test('context-length failures compact and retry at most once', () {
    final source = File(
      'lib/widgets/ai_assistant_panel_tooling.dart',
    ).readAsStringSync();

    expect(source, contains('didContextRecovery'));
    expect(
      source,
      contains('_compactHistoryIfNeeded(gen, config, force: true)'),
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

  testWidgets('keeps following rapid consecutive transcript updates', (
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

    for (var i = 0; i < 6; i++) {
      await tester.enterText(find.byType(TextField), '/help');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    final position = tester
        .widget<ListView>(find.byType(ListView))
        .controller!
        .position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.1));
  });

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
