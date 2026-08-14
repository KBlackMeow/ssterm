import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/command.dart';
import 'package:ssterm/widgets/cmd_picker_button.dart';

void main() {
  testWidgets('aligns menu title size and first-character spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CmdPickerButton(
            onInsert: (_) {},
            loadCommands: () async => const <Command>[],
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.code));
    await tester.pumpAndSettle();

    final header = tester.widget<Padding>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Padding &&
            widget.padding == const EdgeInsets.fromLTRB(16, 16, 16, 8) &&
            widget.child is Text &&
            (widget.child as Text).data == 'Insert command',
      ),
    );
    final title = header.child as Text;
    expect(title.style!.fontSize, 12);
    expect(header.padding, const EdgeInsets.fromLTRB(16, 16, 16, 8));
    expect(
      tester.getTopLeft(find.text('Insert command')).dx,
      tester.getTopLeft(find.text('No saved commands')).dx,
    );
  });

  testWidgets('opens an empty-state panel when no commands are saved', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CmdPickerButton(
            onInsert: (_) {},
            loadCommands: () async => const <Command>[],
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.code));
    await tester.pumpAndSettle();

    expect(find.text('No saved commands'), findsOneWidget);
    expect(find.text('Add commands in Settings > Commands.'), findsOneWidget);
  });
}
