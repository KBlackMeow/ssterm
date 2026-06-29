import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('alt buffer entry clears leaked underline style', () {
    final terminal = Terminal();

    terminal.write('\x1b[4m');
    expect(terminal.cursor.isUnderline, isTrue);

    terminal.write('\x1b[?1049h');
    expect(terminal.cursor.isUnderline, isFalse);

    terminal.write('x');
    expect(terminal.buffer.lines[0].getAttributes(0), equals(0));

    terminal.write('\x1b[?1049l');
    expect(terminal.cursor.isUnderline, isFalse);
  });

  test('alt buffer re-entry clears content and homes the cursor', () {
    final terminal = Terminal();
    terminal.resize(80, 24);

    terminal.write('shell prompt');
    terminal.write('\x1b[?1049h');
    terminal.write('\x1b[12;31Hold claude frame');
    expect(terminal.buffer.cursorX, greaterThan(0));
    expect(terminal.buffer.cursorY, equals(11));

    terminal.write('\x1b[?1049l');
    terminal.write('\x1b[?1049h');

    expect(terminal.isUsingAltBuffer, isTrue);
    expect(terminal.buffer.cursorX, equals(0));
    expect(terminal.buffer.cursorY, equals(0));
    expect(
      terminal.buffer.getText().trim(),
      isEmpty,
      reason: 'a new Claude session must not reuse its previous frame',
    );

    terminal.write('new frame');
    expect(terminal.buffer.lines[0].toString(), startsWith('new frame'));
    expect(terminal.buffer.lines[11].toString(), isEmpty);
  });

  test('erase clears text attributes from blank cells', () {
    final terminal = Terminal();

    terminal.write('\x1b[4mhello');
    terminal.write('\r\x1b[K');

    expect(terminal.buffer.lines[0].getAttributes(0), equals(0));
  });

  test(
    'erase below cursor removes a stale Claude footer after shell prompt',
    () {
      final terminal = Terminal();
      terminal.resize(100, 10);

      terminal.write('\x1b[8;1H Enter to confirm · Esc to cancel');
      terminal.write('\x1b[6;1H(base) PS C:\\Users\\illya> ');
      terminal.write('\x1b[m\x1b[?25h\x1b[J');

      expect(
        terminal.buffer.lines[5].toString(),
        startsWith(r'(base) PS C:\Users\illya> '),
      );
      expect(terminal.buffer.lines[7].toString(), isEmpty);
    },
  );

  test('host recovery removes underline already written into buffer cells', () {
    final terminal = Terminal();

    terminal.write('\x1b[4mWindows PowerShell');
    expect(
      terminal.buffer.lines[0].getAttributes(0) & CellAttr.underline,
      equals(CellAttr.underline),
    );

    terminal.write('\x1b[m');
    terminal.clearBufferTextAttributes(CellAttr.underline);

    for (var column = 0; column < 'Windows PowerShell'.length; column++) {
      expect(
        terminal.buffer.lines[0].getAttributes(column) & CellAttr.underline,
        equals(0),
      );
    }
  });
}
