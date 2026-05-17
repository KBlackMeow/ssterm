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
    expect(terminal.cursor.isUnderline, isTrue);
  });

  test('erase clears text attributes from blank cells', () {
    final terminal = Terminal();

    terminal.write('\x1b[4mhello');
    terminal.write('\r\x1b[K');

    expect(terminal.buffer.lines[0].getAttributes(0), equals(0));
  });
}
