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

  test('answers consecutive DA1 queries during Fish startup', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[0c\x1b[0c');

    expect(output, ['\x1b[?1;2c', '\x1b[?1;2c']);
  });

  test('reports the active background color for OSC 11 queries', () {
    final output = <String>[];
    final terminal = Terminal(
      onOutput: output.add,
      capabilities: const TerminalCapabilities(backgroundRgb: 0x123456),
    );

    terminal.write('\x1b]11;?\x1b\\');

    expect(output, ['\x1b]11;rgb:1212/3434/5656\x1b\\']);
  });

  test('preserves the BEL terminator for OSC 11 queries', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b]11;?\x07');

    expect(output, ['\x1b]11;rgb:1e1e/1e1e/1e1e\x07']);
  });

  test('reports only implemented iTerm2 public features', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b]1337;Capabilities\x1b\\');

    expect(output, ['\x1b]1337;Capabilities=T3MSc6Ts2B\x1b\\']);
  });

  test('answers repeated feature queries with byte-identical replies', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b]1337;Capabilities\x1b\\');
    terminal.write('\x1b]1337;Capabilities\x1b\\');

    expect(output, [
      '\x1b]1337;Capabilities=T3MSc6Ts2B\x1b\\',
      '\x1b]1337;Capabilities=T3MSc6Ts2B\x1b\\',
    ]);
  });

  test('does not execute unsupported iTerm2 private commands', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b]1337;File=name=test:payload\x1b\\');
    terminal.write('\x1b]1337;SetProfile=Other\x1b\\');

    expect(output, isEmpty);
  });

  test('handles Fish 4.7+ startup probes in one arbitrary output chunk', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write(
      '\x1b[?u' // kitty keyboard state
      '\x1b[>0q' // XTVERSION
      '\x1b]11;?\x1b\\' // background color
      '\x1b[?1049h' // Fish's temporary alternate screen
      '\x1bP+q696e646e\x1b\\' // indn
      '\x1bP+q71756572792d6f732d6e616d65\x1b\\' // query-os-name
      '\x1b[?1049l'
      '\x1b[0c', // DA1
    );

    expect(output, [
      '\x1b[?0u',
      '\x1bP>|SSTerm\x1b\\',
      '\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\',
      '\x1bP1+r696e646e=1b5b257031256453\x1b\\',
      '\x1bP0+r\x1b\\',
      '\x1b[?1;2c',
    ]);
  });
}
