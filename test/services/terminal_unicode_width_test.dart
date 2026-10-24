import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/rust_terminal_core.dart';
import 'package:xterm/xterm.dart';

Set<int> _property(String file, Set<String> properties) {
  final result = <int>{};
  for (final line in File('tool/unicode/16.0.0/$file').readAsLinesSync()) {
    final fields = line.split('#').first.split(';');
    if (fields.length != 2 || !properties.contains(fields[1].trim())) continue;
    final range = fields[0].trim().split('..');
    final start = int.parse(range.first, radix: 16);
    final end = int.parse(range.last, radix: 16);
    for (var scalar = start; scalar <= end; scalar++) {
      result.add(scalar);
    }
  }
  return result;
}

List<String> _spinnerFrames() => [
  '\x1b[?1049h\x1b[23;1H',
  for (var frame = 0; frame < 12; frame++)
    (() {
      // Strix's six-cell sweep alternates text-presentation squares and dots.
      final sweep = List.generate(
        6,
        (i) => (i + frame) % 6 < 4 ? '▪' : '·',
      ).join();
      final left = ' $sweep esc stop';
      const right = 'ctrl-q quit';
      return '\r$left${' ' * (80 - left.length - right.length)}$right';
    })(),
];

void main() {
  test('every Unicode 16 emoji uses its declared default presentation', () {
    final emoji = _property('emoji-data.txt', {'Emoji'});
    final defaultEmoji = _property('emoji-data.txt', {'Emoji_Presentation'});
    final wide = _property('EastAsianWidth.txt', {'W', 'F'});
    final policy = TerminalWidthPolicy();
    expect(emoji.length, greaterThan(1400));
    for (final scalar in emoji) {
      final expected = wide.contains(scalar) || defaultEmoji.contains(scalar)
          ? 2
          : 1;
      expect(
        policy.widthOf(scalar),
        expected,
        reason: 'U+${scalar.toRadixString(16)} default Unicode presentation',
      );
    }
  });

  test(
    'all nonzero modern widths follow Unicode 16 EAW and emoji presentation',
    () {
      final wide = _property('EastAsianWidth.txt', {'W', 'F'});
      final emoji = _property('emoji-data.txt', {'Emoji_Presentation'});
      final ambiguous = _property('EastAsianWidth.txt', {'A'});
      for (final doubleAmbiguous in [false, true]) {
        final policy = TerminalWidthPolicy(
          ambiguousDoubleWidth: doubleAmbiguous,
        );
        for (var scalar = 0x20; scalar <= 0x10ffff; scalar++) {
          if (scalar >= 0xd800 && scalar <= 0xdfff) continue;
          final actual = policy.widthOf(scalar);
          if (actual == 0) {
            continue; // Combining/control policy is tested separately.
          }
          final expected =
              wide.contains(scalar) ||
                  emoji.contains(scalar) ||
                  (doubleAmbiguous && ambiguous.contains(scalar))
              ? 2
              : 1;
          if (actual != expected) {
            fail(
              'U+${scalar.toRadixString(16)} ambiguous=$doubleAmbiguous: '
              'expected $expected cells, got $actual',
            );
          }
        }
      }
    },
  );

  test('text symbols widen only with VS16, including split PTY writes', () {
    for (final symbol in '©®™↔▪▫▶☀✉✔❤'.runes) {
      final base = String.fromCharCode(symbol);
      for (final (selector, width) in [
        ('', 1),
        ('\u{fe0e}', 1),
        ('\u{fe0f}', 2),
      ]) {
        final terminal = Terminal()..resize(8, 1);
        terminal.write(base);
        terminal.write(selector);
        terminal.write('X');
        final line = terminal.buffer.lines[0];
        expect(
          line.getWidth(0),
          width,
          reason: 'U+${symbol.toRadixString(16)} $selector',
        );
        expect(line.getCodePoint(width), 'X'.codeUnitAt(0));
      }
    }
  });

  test(
    'Strix sweep refreshes one row without wrapping the quit hint in Dart',
    () {
      final terminal = Terminal()..resize(80, 24);
      for (final frame in _spinnerFrames()) {
        terminal.write(frame);
      }
      final lines = [
        for (var row = 0; row < 24; row++)
          terminal.buffer.lines[row].toString().trimRight(),
      ];
      expect(lines.where((row) => row.contains('esc stop')), hasLength(1));
      expect(lines[22], endsWith('ctrl-q quit'));
      expect(lines[23], isEmpty);
    },
  );

  final library = Platform.isMacOS
      ? 'native/terminal_core/target/release/libssterm_terminal_core.dylib'
      : Platform.isWindows
      ? 'native/terminal_core/target/release/ssterm_terminal_core.dll'
      : 'native/terminal_core/target/release/libssterm_terminal_core.so';
  test(
    'Strix sweep refreshes one row without wrapping the quit hint in Rust',
    () {
      final core = RustTerminalCore.open(
        columns: 80,
        rows: 24,
        libraryPath: library,
      );
      addTearDown(core.close);
      for (final frame in _spinnerFrames()) {
        core.feed(Uint8List.fromList(utf8.encode(frame)));
      }
      final lines = [for (var row = 0; row < 24; row++) core.rowText(row)];
      expect(lines.where((row) => row.contains('esc stop')), hasLength(1));
      expect(lines[22], endsWith('ctrl-q quit'));
      expect(lines[23], isEmpty);
    },
    skip: File(library).existsSync() ? false : 'Build the native core first',
  );
}
