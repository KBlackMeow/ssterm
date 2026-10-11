import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('bare media controls follow reference terminal widths', () {
    for (final symbol in '⏭⏮⏯⏱⏲⏸⏹⏺'.runes) {
      final terminal = Terminal()..resize(4, 1);
      terminal.write('${String.fromCharCode(symbol)}X');
      expect(terminal.buffer.cursorX, 2,
          reason: 'U+${symbol.toRadixString(16)}');
    }
  });

  test('text-presentation pause symbol does not leave redraw artifacts', () {
    final terminal = Terminal()..resize(12, 1);
    terminal.write('⏸\x1b[1Cabc)');
    expect(terminal.buffer.cursorX, 6);

    terminal.write('\r      ');
    expect(terminal.buffer.lines[0].toString().trimRight(), isEmpty);
  });
}
