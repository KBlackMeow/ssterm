import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('BufferLine.getText()', () {
    test('should return the text', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(), 'Hello World');
    });

    test('getText() should support wide characters', () {
      final text = '😀😁😂🤣😃';
      final terminal = Terminal();
      terminal.write(text);
      expect(terminal.buffer.lines[0].getText(), equals(text));
    });

    test('uses ChatCode-compatible widths for status symbols and emoji', () {
      final terminal = Terminal();
      terminal.write('✉⏺${String.fromCharCode(0x1fae8)}X');

      final line = terminal.buffer.lines[0];
      expect(line.getWidth(0), equals(2));
      expect(line.getCodePoint(1), equals(0));
      expect(line.getWidth(2), equals(1));
      expect(line.getWidth(3), equals(2));
      expect(line.getCodePoint(4), equals(0));
      expect(line.getCodePoint(5), equals('X'.codeUnitAt(0)));
    });

    test('does not retain spinner text beside the ChatCode tool marker', () {
      final terminal = Terminal();
      terminal.write('✢ Burrowing...');
      terminal.write('\r⏺\x1b[1C当前');

      final line = terminal.buffer.lines[0];
      expect(line.getWidth(0), equals(1));
      expect(line.getCodePoint(1), equals(' '.codeUnitAt(0)));
      expect(line.getCodePoint(2), equals('当'.runes.single));
      expect(line.getCodePoint(3), equals(0));
      expect(line.getCodePoint(4), equals('前'.runes.single));
    });

    test('keeps ornamental stars such as U+2722 single-width', () {
      final terminal = Terminal();
      terminal.write('✢X');

      final line = terminal.buffer.lines[0];
      expect(line.getWidth(0), equals(1));
      expect(line.getCodePoint(1), equals('X'.codeUnitAt(0)));
    });

    test('can specify a range', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 5), 'Hello');
    });

    test('can handle invalid ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 100), 'Hello World');
    });

    test('can handle negative ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(-100, 100), 'Hello World');
    });

    test('can handle reversed ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(5, 0), '');
    });

    test('erase should clear text attributes from blank cells', () {
      final terminal = Terminal();
      terminal.write('\x1b[4mhello');
      terminal.write('\r\x1b[K');

      expect(terminal.buffer.lines[0].getAttributes(0), equals(0));
    });
  });

  group('BufferLine.getTrimmedLength()', () {
    test('can get trimmed length', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(), equals(text.length));
    });

    test('can get trimmed length with wide characters', () {
      final terminal = Terminal();
      final text = '😀😁😂🤣😃';

      terminal.write(text);

      expect(terminal.buffer.lines[0].getTrimmedLength(), equals(text.length));
    });

    test('can handle length larger than the line', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(1000), equals(text.length));
    });

    test('can handle negative start', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(-1000), equals(0));
    });
  });

  group('BufferLine.resize', () {
    test('can resize', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      line.resize(20);

      expect(line.length, equals(20));
    });
  });

  group('Buffer.createAnchor', () {
    test('works', () {
      final terminal = Terminal();
      final line = terminal.buffer.lines[3];
      final anchor = line.createAnchor(5);

      terminal.insertLines(5);
      expect(anchor.x, 5);
      expect(anchor.y, 8);

      terminal.buffer.clear();
      expect(line.attached, false);
      expect(anchor.attached, false);
    });

    test('line dispose detaches all anchors', () {
      final line = BufferLine(10);
      final anchors = [
        line.createAnchor(1),
        line.createAnchor(3),
        line.createAnchor(5),
      ];

      line.dispose();

      for (final anchor in anchors) {
        expect(anchor.attached, false);
      }
    });
  });
}
