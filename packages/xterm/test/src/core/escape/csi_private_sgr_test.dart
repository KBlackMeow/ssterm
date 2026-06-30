import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// `CSI > Ps m` (XTMODKEYS / modifyOtherKeys) and other private-prefixed
/// (`<`, `=`, `>`) CSI `m` forms are NOT Select Graphic Rendition. They must
/// not touch text attributes. Claude Code / ConPTY emit `\x1b[>4m`, which was
/// being mis-parsed as `SGR 4` (underline on) — leaking underline into the
/// shell prompt and everything after it.
void main() {
  bool underline(Terminal t) => (t.cursor.attrs & CellAttr.underline) != 0;

  test('CSI > 4 m (modifyOtherKeys) does NOT set underline', () {
    final t = Terminal()..write('\x1b[>4m');
    expect(underline(t), isFalse);
  });

  test('the exact claude teardown sequence leaves no underline', () {
    final t = Terminal()
      ..write('\x1b[>4m\x1b[<u\x1b[?2031l\x1b[?2004l')
      ..write('Claude is up to date!');
    expect(underline(t), isFalse);
  });

  test('plain CSI 4 m still sets underline (no regression)', () {
    final t = Terminal()..write('\x1b[4m');
    expect(underline(t), isTrue);
  });

  test('CSI 0 m after private form still resets cleanly', () {
    final t = Terminal()
      ..write('\x1b[4m')
      ..write('\x1b[>4m')
      ..write('\x1b[0m');
    expect(underline(t), isFalse);
  });

  // The parser captures a leading ':'/';' as a "prefix" too, but those are
  // (malformed) empty SGR parameters, NOT private markers — they must still be
  // treated as SGR. Guarding only against the real markers `< = > ?` keeps them.
  test('leading-semicolon SGR is still applied', () {
    expect(underline(Terminal()..write('\x1b[;4m')), isTrue);
    expect(
      (Terminal()..write('\x1b[;1m')).cursor.attrs & CellAttr.bold != 0,
      isTrue,
    );
  });
}
