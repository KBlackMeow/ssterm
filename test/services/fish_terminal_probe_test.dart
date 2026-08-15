import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('Fish probe replies use the same terminal output channel as user input', () {
    final forwarded = <String>[];
    final terminal = Terminal(onOutput: forwarded.add);

    terminal.write('\x1b[?u\x1bP+q696e646e\x1b\\\x1b[0c');

    expect(forwarded, [
      '\x1b[?0u',
      '\x1bP1+r696e646e=1b5b257031256453\x1b\\',
      '\x1b[?1;2c',
    ]);
    expect(localShellStartupArguments('/opt/homebrew/bin/fish'), isEmpty);
  });
}
