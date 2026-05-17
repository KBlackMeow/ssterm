import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/input/keytab/keytab.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('defaultInputHandler', () {
    test('supports numpad enter', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.keyInput(TerminalKey.numpadEnter);
      expect(output, ['\r']);
    });
  });

  group('arrow key encoding uses cursorKeysMode, not appKeypadMode', () {
    // Regression: when appKeypadMode is true but cursorKeysMode is false,
    // arrow keys must still use ANSI sequences (\E[A/B/C/D).  Previously
    // appKeypadMode was (incorrectly) used for appCursorKeys, which caused
    // vi to receive \EOB (ESC + 'O' + 'B') and misinterpret 'O' as the
    // "open line above" command, silently entering INSERT mode.

    test('sends ANSI arrows when only appKeypadMode is set', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      // Simulate a pager (e.g. `less`) that sets application keypad WITHOUT
      // setting application cursor keys.
      terminal.write('\x1b='); // ESC = → appKeypadMode = true
      expect(terminal.appKeypadMode, isTrue);
      expect(terminal.cursorKeysMode, isFalse);

      terminal.keyInput(TerminalKey.arrowUp);
      expect(output.last, equals('\x1b[A'),
          reason: 'up arrow must be ANSI when cursorKeysMode is false');

      terminal.keyInput(TerminalKey.arrowDown);
      expect(output.last, equals('\x1b[B'),
          reason: 'down arrow must be ANSI when cursorKeysMode is false');
    });

    test('sends application arrows only when cursorKeysMode is set', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      // Simulate vim/emacs that explicitly enables application cursor keys.
      terminal.write('\x1b[?1h'); // DEC 1 → cursorKeysMode = true
      expect(terminal.cursorKeysMode, isTrue);

      terminal.keyInput(TerminalKey.arrowUp);
      expect(output.last, equals('\x1bOA'),
          reason: 'up arrow must be application when cursorKeysMode is true');

      terminal.keyInput(TerminalKey.arrowDown);
      expect(output.last, equals('\x1bOB'),
          reason: 'down arrow must be application when cursorKeysMode is true');
    });

    test('entering alt buffer (1049) resets cursorKeysMode and appKeypadMode', () {
      final terminal = Terminal();

      // Shell had both modes active (e.g. after using less+vim).
      terminal.write('\x1b=');      // appKeypadMode = true
      terminal.write('\x1b[?1h');   // cursorKeysMode = true
      expect(terminal.appKeypadMode, isTrue);
      expect(terminal.cursorKeysMode, isTrue);

      terminal.write('\x1b[?1049h');
      expect(terminal.appKeypadMode, isFalse,
          reason: 'appKeypadMode must be reset on alt buffer entry');
      expect(terminal.cursorKeysMode, isFalse,
          reason: 'cursorKeysMode must be reset on alt buffer entry');
    });

    test('entering alt buffer (47) resets cursorKeysMode and appKeypadMode', () {
      final terminal = Terminal();
      terminal.write('\x1b=');
      terminal.write('\x1b[?1h');

      terminal.write('\x1b[?47h');
      expect(terminal.appKeypadMode, isFalse);
      expect(terminal.cursorKeysMode, isFalse);
    });
  });

  group('KeytabInputHandler', () {
    test('can insert modifier code', () {
      final handler = KeytabInputHandler(
        Keytab.parse(r'key Home +AnyMod : "\E[1;*H"'),
      );

      final terminal = Terminal(inputHandler: handler);

      late String output;

      terminal.onOutput = (data) {
        output = data;
      };

      terminal.keyInput(TerminalKey.home, ctrl: true);

      expect(output, '\x1b[1;5H');

      terminal.keyInput(TerminalKey.home, shift: true);

      expect(output, '\x1b[1;2H');
    });
  });
}
