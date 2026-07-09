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

    test('East Asian Ambiguous symbols occupy one cell by default', () {
      final terminal = Terminal();
      terminal.write('A℃℉①─B');

      final line = terminal.buffer.lines[0];
      expect(line.getText(0, 6), 'A℃℉①─B');
      expect(line.getWidth(1), 1);
      expect(line.getWidth(2), 1);
      expect(line.getWidth(3), 1);
      expect(line.getWidth(4), 1);
      expect(line.getCodePoint(5), 'B'.codeUnitAt(0));
    });

    test('can treat East Asian Ambiguous symbols as two cells', () {
      const compat = TerminalCompat(ambiguousCharsAreWide: true);
      final terminal = Terminal(compat: compat);
      terminal.write('A℃℉①─B');

      final line = terminal.buffer.lines[0];
      expect(line.getText(0, 10), 'A℃℉①─B');
      expect(line.getWidth(1), 2);
      expect(line.getWidth(3), 2);
      expect(line.getWidth(5), 2);
      expect(line.getWidth(7), 2);
      expect(line.getCodePoint(9), 'B'.codeUnitAt(0));
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
