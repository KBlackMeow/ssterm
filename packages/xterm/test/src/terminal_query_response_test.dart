import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('responds to Fish indn XTGETTCAP request', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1bP+q696e646e\x1b\\');

    expect(output, ['\x1bP1+r696e646e=1b5b257031256453\x1b\\']);
  });

  test('parses a split XTGETTCAP request without writing it to the screen', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1bP+q696e');
    terminal.write('646e\x1b\\');

    expect(output, ['\x1bP1+r696e646e=1b5b257031256453\x1b\\']);
    expect(terminal.buffer.lines[0].toString(), isEmpty);
  });

  test('does not claim an unsupported XTGETTCAP request', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1bP+q71756572795f6f735f6e616d65\x1b\\');

    expect(output, ['\x1bP0+r\x1b\\']);
  });

  test('reports the disabled kitty keyboard protocol state', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?u');

    expect(output, ['\x1b[?0u']);
  });

  test('identifies SSTerm for XTVERSION queries', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[>0q');

    expect(output, ['\x1bP>|SSTerm\x1b\\']);
  });
}
