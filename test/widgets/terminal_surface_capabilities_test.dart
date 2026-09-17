import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/terminal_settings.dart';
import 'package:ssterm/widgets/terminal_surface.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('publishes the active theme background to OSC 11', (
    tester,
  ) async {
    final terminal = Terminal();
    final settings = TerminalSettings()
      ..setCustomColor('background', const Color(0xff123456));

    await tester.pumpWidget(
      MaterialApp(
        home: TerminalSurface(terminal: terminal, settings: settings),
      ),
    );

    expect(terminal.capabilities.backgroundRgb, 0x123456);
  });

  testWidgets('terminal history follows wheel scrolling', (tester) async {
    final terminal = Terminal(maxLines: 200);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 120,
            child: TerminalSurface(
              terminal: terminal,
              settings: TerminalSettings(),
            ),
          ),
        ),
      ),
    );

    for (var line = 0; line < 100; line++) {
      terminal.write('line $line\r\n');
    }
    await tester.pump();

    final scrollable = tester.widget<Scrollable>(find.byType(Scrollable).first);
    final scrollController = scrollable.controller!;
    expect(scrollController.position.maxScrollExtent, greaterThan(0));
    expect(
      scrollController.position.pixels,
      scrollController.position.maxScrollExtent,
    );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final position = tester.getCenter(find.byType(TerminalView));
    await tester.sendEventToBinding(pointer.hover(position));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
    await tester.pump();

    expect(
      scrollController.position.pixels,
      lessThan(scrollController.position.maxScrollExtent),
    );
  });
}
