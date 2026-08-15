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
}
