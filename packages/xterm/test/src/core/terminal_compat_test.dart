import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('detectTerminalHostPlatform', () {
    test('returns a non-unknown platform in Flutter tests', () {
      expect(
        detectTerminalHostPlatform(),
        isNot(equals(TerminalTargetPlatform.unknown)),
      );
    });
  });

  group('TerminalCompat', () {
    test('vim is default on Terminal', () {
      final terminal = Terminal();
      expect(terminal.compat.altDecScRcPositionOnly, isTrue);
      expect(terminal.compat.altStripUnderlineOnWrite, isTrue);
      expect(terminal.compat.altScrollDebounceMs, equals(8));
    });

    test('strict disables vim workarounds', () {
      const strict = TerminalCompat.strict;
      expect(strict.altDecScRcPositionOnly, isFalse);
      expect(strict.altStripUnderlineOnWrite, isFalse);
      expect(strict.altScrollDebounceMs, equals(0));
    });
  });
}
