import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/command.dart';
import 'package:ssterm/views/settings/settings_dialogs.dart';

void main() {
  testWidgets('explains why an incomplete command cannot be added', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );

    showDialog<void>(
      context: tester.element(find.byType(Scaffold)),
      builder: (_) => const CommandDialog(),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(find.text('Name and command are required.'), findsOneWidget);
  });

  testWidgets('returns a command after both required fields are filled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );

    final result = showDialog<Command>(
      context: tester.element(find.byType(Scaffold)),
      builder: (_) => const CommandDialog(),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'List files');
    await tester.enterText(fields.at(1), 'Shows the current directory');
    await tester.enterText(fields.at(2), 'ls -la');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(
      await result,
      isA<Command>()
          .having((command) => command.name, 'name', 'List files')
          .having((command) => command.command, 'command', 'ls -la'),
    );
  });
}
