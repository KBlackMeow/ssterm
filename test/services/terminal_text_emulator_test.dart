import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/terminal_text_emulator.dart';

void main() {
  String r(String s) => TerminalTextEmulator.render(s);

  test('plain text is returned untouched', () {
    expect(r('a\nb  \n\tc\n'), 'a\nb  \n\tc\n');
  });

  test('carriage return overwrites the line', () {
    expect(r('Progress 10%\rProgress 55%\rDone\x1b[K\n'), 'Done\n');
    expect(r('abcdef\rXY\n'), 'XYcdef\n');
  });

  test('CRLF behaves as newline', () {
    expect(r('a\r\nb\r\n'), 'a\nb\n');
  });

  test('erase line and SGR are interpreted', () {
    expect(r('\x1b[31mred\x1b[0m\n'), 'red\n');
    expect(r('status 1\r\x1b[2Kstatus 2\n'), 'status 2\n');
    expect(r('abcdef\r\x1b[3C\x1b[K\n'), 'abc\n');
  });

  test('cursor up repaints a block', () {
    expect(r('a1\nb1\n\x1b[2Aa2\nb2\n'), 'a2\nb2\n');
  });

  test('OSC, private modes and charset are dropped', () {
    expect(r('\x1b]0;title\x07x\x1b[?25ly\x1b(Bz\x1b]8;;u\x1b\\w'), 'xyzw');
  });

  test('sequences split across writes still parse', () {
    final e = TerminalTextEmulator()
      ..write('ab\x1b[')
      ..write('2Kcd\rX');
    expect(e.text, 'X cd'); // ESC[2K erases but does not move the cursor
  });

  test('hashcat-style status stream collapses to the last frame', () {
    final b = StringBuffer('Initializing backend runtime...\n');
    for (var i = 0; i < 100; i++) {
      b.write('\x1b[2K\rSpeed.#1.........:  $i H/s\x1b[?25l');
    }
    b.write('\n');
    expect(
      r(b.toString()),
      'Initializing backend runtime...\nSpeed.#1.........:  99 H/s\n',
    );
  });

  test('maxRows bounds memory for live tail', () {
    final e = TerminalTextEmulator(maxRows: 5);
    for (var i = 0; i < 1000; i++) {
      e.write('line $i\n');
    }
    expect(e.lines.last, 'line 999');
    expect(e.lines.length <= 11, isTrue);
  });
}
