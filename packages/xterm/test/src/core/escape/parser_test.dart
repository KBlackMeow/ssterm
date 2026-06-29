import 'dart:convert';

import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.resize(80, 24));
    });

    group('alt buffer cursor style reset (vi underline bug)', () {
      // Regression: shell PS1 underline must not bleed into full-screen apps.
      // All three alt-screen entry modes must reset cursor text attributes.

      test('mode 1049 resets cursor style and restores on exit', () {
        final terminal = Terminal();

        terminal.write('\x1b[4m');
        expect(terminal.cursor.isUnderline, isTrue);

        terminal.write('\x1b[?1049h');
        expect(terminal.cursor.isUnderline, isFalse,
            reason: 'cursor should be clean inside alt buffer (mode 1049)');

        terminal.write('x');
        expect(terminal.buffer.lines[0].getAttributes(0), equals(0),
            reason: 'char written in alt buffer must have no underline');

        terminal.write('\x1b[?1049l');
        expect(terminal.cursor.isUnderline, isTrue,
            reason: 'shell cursor attrs must be restored on exit');
      });

      test('mode 47 resets cursor style (classic vi)', () {
        final terminal = Terminal();

        terminal.write('\x1b[4m');
        expect(terminal.cursor.isUnderline, isTrue);

        // Classic vi uses ?47h, not ?1049h
        terminal.write('\x1b[?47h');
        expect(terminal.cursor.isUnderline, isFalse,
            reason: 'cursor should be clean inside alt buffer (mode 47)');

        terminal.write('x');
        expect(terminal.buffer.lines[0].getAttributes(0), equals(0),
            reason: 'char written in alt buffer must have no underline');

        terminal.write('\x1b[?47l');
        expect(terminal.cursor.isUnderline, isTrue,
            reason: 'shell cursor attrs must be restored on exit');
      });

      test('mode 1047 resets cursor style', () {
        final terminal = Terminal();

        terminal.write('\x1b[4m');
        expect(terminal.cursor.isUnderline, isTrue);

        terminal.write('\x1b[?1047h');
        expect(terminal.cursor.isUnderline, isFalse,
            reason: 'cursor should be clean inside alt buffer (mode 1047)');

        terminal.write('x');
        expect(terminal.buffer.lines[0].getAttributes(0), equals(0),
            reason: 'char written in alt buffer must have no underline');
      });

      test('DECRC after re-entering alt buffer does not restore stale underline', () {
        // Regression: alt buffer DECSC save slot kept shell underline across
        // vi sessions; the first DECRC in a new session re-applied it so
        // newly scrolled lines were written with underline.
        final terminal = Terminal();

        terminal.write('\x1b[4m');
        terminal.write('\x1b[?1049h');
        terminal.write('\x1b[4m');
        terminal.write('\x1b7'); // DECSC while underline active

        terminal.write('\x1b[?1049l');
        terminal.write('\x1b[?1049h'); // re-enter vi

        terminal.write('\x1b8'); // DECRC — must not restore stale underline
        expect(terminal.cursor.isUnderline, isFalse);

        terminal.write('line after decrc');
        for (var col = 0; col < 'line after decrc'.length; col++) {
          expect(
            terminal.buffer.lines[terminal.buffer.cursorY].getAttributes(col),
            equals(0),
          );
        }
      });

      test('alt buffer write does not store underline on cells when cursor has underline', () {
        final terminal = Terminal();
        terminal.write('\x1b[?1049h');
        terminal.write('\x1b[4m');
        expect(terminal.cursor.isUnderline, isTrue);

        terminal.write('tilde~line');
        final lineIdx = terminal.buffer.absoluteCursorY;
        for (var col = 0; col < 'tilde~line'.length; col++) {
          expect(
            terminal.buffer.lines[lineIdx].getAttributes(col) & 8,
            equals(0),
            reason: 'col $col must not have underline on cell',
          );
        }
      });

      test('DECRC does not restore text attrs saved with dirty underline state', () {
        // Regression: vim uses DECSC/DECRC for position save/restore only and
        // manages SGR attr state (screen_attr) independently. If DECRC restores
        // attrs saved while underline was set, it desynchronises the terminal's
        // cursor.attrs from vim's screen_attr, causing newly scrolled-in
        // content to appear underlined even though vim emitted no \x1b[4m.
        final terminal = Terminal();
        terminal.write('\x1b[?1049h'); // enter alt buffer

        // vim draws an Identifier with underline, does NOT reset after
        terminal.write('\x1b[4m');
        terminal.write('identifier');
        // cursor.attrs now has underline=on; vim's screen_attr=underline

        // vim saves cursor (e.g. to go update status bar)
        terminal.write('\x1b7'); // DECSC with underline=on in saved slot

        // status bar update resets attrs
        terminal.write('\x1b[0m'); // \x1b[m — vim's screen_attr=0, cursor.attrs=0
        terminal.write('status bar');

        // vim restores cursor to edit area; screen_attr still 0 in vim's model
        terminal.write('\x1b8'); // DECRC — must NOT restore underline

        expect(terminal.cursor.isUnderline, isFalse,
            reason: 'DECRC must not restore saved underline attrs');

        // vim moves to a new line and writes new scroll-in content
        terminal.write('\r\n');
        terminal.write('new scrolled content');
        final lineIdx = terminal.buffer.absoluteCursorY;
        for (var col = 0; col < 'new scrolled content'.length; col++) {
          expect(
            terminal.buffer.lines[lineIdx].getAttributes(col),
            equals(0),
            reason: 'col $col of scroll content must have no underline',
          );
        }
      });

      test('scrolled-in content written while cursor has underline gets no underline (mode 47)', () {
        // Simulate vi scroll: shell had underline, vi enters via mode 47,
        // writes some content with underline (e.g. status bar), scrolls,
        // then writes new-line content — that content must NOT be underlined.
        final terminal = Terminal();

        // Shell sets underline
        terminal.write('\x1b[4m');

        // Classic vi enters alt buffer via mode 47
        terminal.write('\x1b[?47h');
        expect(terminal.cursor.isUnderline, isFalse);

        // vi writes some content (say, status bar with underline)
        terminal.write('\x1b[4m');
        terminal.write('STATUS BAR');
        terminal.write('\x1b[0m'); // vi resets after status bar

        // vi scrolls: new empty line arrives, cursor positioned there
        // (simulate with a fresh line move + write)
        terminal.write('\r\n');
        terminal.write('new content after scroll');

        // The "new content" line should NOT be underlined
        // (cursor was reset with \x1b[0m before writing)
        final lineIdx = terminal.buffer.absoluteCursorY;
        for (var col = 0; col < 'new content after scroll'.length; col++) {
          expect(terminal.buffer.lines[lineIdx].getAttributes(col), equals(0),
              reason: 'column $col of scrolled-in content must have no underline');
        }
      });
    });

    group('XTERM_COMPAT features', () {
      test('DECSCUSR sets cursor shape (block)', () {
        final terminal = Terminal();
        terminal.write('\x1b[1 q');
        expect(terminal.decscusrShape, equals(1));
      });

      test('DECSCUSR sets cursor shape (underline)', () {
        final terminal = Terminal();
        terminal.write('\x1b[3 q');
        expect(terminal.decscusrShape, equals(3));
      });

      test('DECSCUSR sets cursor shape (bar)', () {
        final terminal = Terminal();
        terminal.write('\x1b[5 q');
        expect(terminal.decscusrShape, equals(5));
      });

      test('DECSCUSR without space intermediate is ignored', () {
        final terminal = Terminal();
        terminal.write('\x1b[1q');
        expect(terminal.decscusrShape, equals(0));
      });

      test('OSC 7 sets working directory', () {
        String? capturedUri;
        final terminal = Terminal()
          ..onWorkingDirectoryChange = (uri) => capturedUri = uri;
        terminal.write('\x1b]7;file:///home/user\x07');
        expect(capturedUri, equals('file:///home/user'));
      });

      test('OSC 52 clipboard write', () {
        String? captured;
        final terminal = Terminal()
          ..onClipboardWrite = (data) => captured = data;
        final encoded = base64.encode(utf8.encode('hello'));
        terminal.write('\x1b]52;c;$encoded\x07');
        expect(captured, equals('hello'));
      });

      test('OSC 52 clipboard request', () {
        var requested = false;
        final terminal = Terminal()..onClipboardRead = () => requested = true;
        terminal.write('\x1b]52;c;?\x07');
        expect(requested, isTrue);
      });

      test('DA2 response contains version 95', () {
        final outputs = <String>[];
        final terminal = Terminal()..onOutput = outputs.add;
        // Write one char at a time to bypass the bulk-write DA throttle guard.
        for (final char in '\x1b[>c'.split('')) {
          terminal.write(char);
        }
        expect(outputs.join(), contains(';95;'));
      });

      test('focus mode sends focus-in on enable', () {
        final terminal = Terminal();
        terminal.write('\x1b[?1004h');
        expect(terminal.reportFocusMode, isTrue);
      });

      test('SGR 4:3 wavy underline stored in cell flags', () {
        final terminal = Terminal();
        terminal.write('\x1b[4:3m');
        terminal.write('X');
        final attrs = terminal.buffer.lines[0].getAttributes(0);
        expect((attrs >> 9) & 0x7, equals(3),
            reason: 'underline style bits should be 3 (wavy)');
      });

      test('SGR 53 overline stored in cell flags', () {
        final terminal = Terminal();
        terminal.write('\x1b[53m');
        terminal.write('X');
        final attrs = terminal.buffer.lines[0].getAttributes(0);
        expect(attrs & (1 << 8), isNot(equals(0)),
            reason: 'overline bit should be set');
      });
    });

    group('TerminalCompat.strict', () {
      test('DECRC restores saved underline attrs', () {
        final terminal = Terminal(compat: TerminalCompat.strict);
        terminal.write('\x1b[?1049h');
        terminal.write('\x1b[4m');
        terminal.write('id');
        terminal.write('\x1b7');
        terminal.write('\x1b[0m');
        terminal.write('\x1b8');
        expect(terminal.cursor.isUnderline, isTrue);
      });

      test('alt write stores underline on cells when cursor has underline', () {
        final terminal = Terminal(compat: TerminalCompat.strict);
        terminal.write('\x1b[?1049h');
        terminal.write('\x1b[4m');
        terminal.write('x');
        expect(
          terminal.buffer.lines[terminal.buffer.cursorY].getAttributes(0) & 8,
          equals(8),
        );
      });
    });
  });
}
