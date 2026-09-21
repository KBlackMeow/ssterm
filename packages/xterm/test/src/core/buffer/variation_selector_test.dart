import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VS16 (U+FE0F) emoji presentation', () {
    test('widens a narrow Extended_Pictographic base and moves the cursor', () {
      final terminal = Terminal()..resize(10, 1);
      // U+2607 is Extended_Pictographic but intentionally narrow by
      // default, so only the selector can make it wide.
      terminal.write('\u{2607}\u{FE0F}X');

      final line = terminal.buffer.lines[0];
      expect(line.getCodePoint(0), equals(0x2607));
      expect(line.getWidth(0), equals(2));
      expect(line.getCodePoint(1), equals(0));
      expect(line.getCodePoint(2), equals(0x58)); // X
    });

    test('does not widen non-pictographic bases', () {
      final terminal = Terminal()..resize(10, 1);
      terminal.write('B\u{FE0F}X');

      final line = terminal.buffer.lines[0];
      expect(line.getCodePoint(0), equals(0x42));
      expect(line.getWidth(0), equals(1));
      expect(line.getCodePoint(1), equals(0x58)); // X directly after
    });

    test('is a no-op after an already-wide base', () {
      final terminal = Terminal()..resize(10, 1);
      terminal.write('✉\u{FE0F}X');

      final line = terminal.buffer.lines[0];
      expect(line.getWidth(0), equals(2));
      expect(line.getCodePoint(2), equals(0x58));
    });

    test('at line start is ignored', () {
      final terminal = Terminal()..resize(10, 1);
      terminal.write('\u{FE0F}X');

      final line = terminal.buffer.lines[0];
      expect(line.getCodePoint(0), equals(0x58));
      expect(line.getWidth(0), equals(1));
    });

    test('does not widen a base written on the last column', () {
      final terminal = Terminal()..resize(3, 1);
      terminal.write('AB\u{2607}');
      terminal.write('\u{FE0F}');

      final line = terminal.buffer.lines[0];
      expect(line.getCodePoint(2), equals(0x2607));
      expect(line.getWidth(2), equals(1));
    });
  });

  group('VS15 (U+FE0E) text presentation', () {
    test('narrows a wide Extended_Pictographic base', () {
      final terminal = Terminal()..resize(10, 1);
      terminal.write('✉\u{FE0E}X');

      final line = terminal.buffer.lines[0];
      expect(line.getCodePoint(0), equals(0x2709));
      expect(line.getWidth(0), equals(1));
      expect(line.getCodePoint(1), equals(0x58)); // X at the freed cell
      expect(line.getCodePoint(2), equals(0));
    });

    test('does not narrow non-pictographic wide characters', () {
      final terminal = Terminal()..resize(10, 1);
      terminal.write('当\u{FE0E}X');

      final line = terminal.buffer.lines[0];
      expect(line.getWidth(0), equals(2));
      expect(line.getCodePoint(2), equals(0x58));
    });

    test('handles a wide base written on the last column', () {
      final terminal = Terminal()..resize(3, 1);
      terminal.write('A✉');
      terminal.write('\u{FE0E}');

      final line = terminal.buffer.lines[0];
      expect(line.getCodePoint(1), equals(0x2709));
      expect(line.getWidth(1), equals(1));
      expect(terminal.buffer.cursorX, equals(2));
    });
  });

  group('TerminalWidthPolicy', () {
    test('modern profile is the default', () {
      final terminal = Terminal();
      expect(terminal.widthPolicy.profile, equals(WidthProfile.modern));
      expect(terminal.widthPolicy.ambiguousDoubleWidth, isFalse);
    });

    test('legacy profile restores pre-emoji double width', () {
      final policy = TerminalWidthPolicy(profile: WidthProfile.legacy);
      expect(policy.widthOf(0x2709), equals(1)); // ✉ narrow again
      expect(policy.widthOf(0x5F53), equals(2)); // 当 still wide (EAW W)
      final modern = TerminalWidthPolicy();
      expect(modern.widthOf(0x2709), equals(2));
    });

    test('ambiguousDoubleWidth widens EAW=A characters only on modern', () {
      final policy = TerminalWidthPolicy(ambiguousDoubleWidth: true);
      expect(policy.widthOf(0x203B), equals(2)); // ※ is ambiguous
      expect(policy.widthOf(0x41), equals(1)); // A is not
      final legacy = TerminalWidthPolicy(
        profile: WidthProfile.legacy,
        ambiguousDoubleWidth: true,
      );
      expect(legacy.widthOf(0x203B), equals(1));
    });

    test('policy changes apply to live terminals on new output', () {
      final terminal = Terminal()..resize(20, 1);
      terminal.write('※');
      expect(terminal.buffer.lines[0].getWidth(0), equals(1));

      terminal.widthPolicy.ambiguousDoubleWidth = true;
      terminal.write('\r※');
      expect(terminal.buffer.lines[0].getWidth(0), equals(2));
    });

    test('variation selectors are inert on the legacy profile', () {
      final terminal = Terminal(
        widthPolicy: TerminalWidthPolicy(profile: WidthProfile.legacy),
      )..resize(10, 1);
      terminal.write('\u{2607}\u{FE0F}X');

      final line = terminal.buffer.lines[0];
      expect(line.getWidth(0), equals(1));
      expect(line.getCodePoint(1), equals(0x58));
    });

    test('cursor-addressed redraw stays aligned across a VS16 pair', () {
      // An Ink-style TUI that models '\u{2607}\u{FE0F}' as two cells skips one
      // unchanged column between the glyph and the following text.
      final terminal = Terminal()..resize(20, 1);
      terminal.write('\u{2607}\u{FE0F} busy…');
      terminal.write('\r\u{2607}\u{FE0F}\x1b[1Cdone');

      final line = terminal.buffer.lines[0];
      expect(line.getWidth(0), equals(2));
      expect(line.getCodePoint(1), equals(0));
      expect(line.getCodePoint(2), equals(0x20)); // skipped space survives
      expect(line.getCodePoint(3), equals('d'.codeUnitAt(0)));
      expect(line.getCodePoint(6), equals('e'.codeUnitAt(0)));
      // The old tail beyond the redrawn span survives until the app erases
      // it, exactly as on a reference terminal.
      expect(line.getCodePoint(7), equals(0x2026)); // …
    });
  });
}
