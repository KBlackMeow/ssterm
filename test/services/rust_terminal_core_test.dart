import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/rust_terminal_core.dart';
import 'package:xterm/xterm.dart';

String _libraryPath() {
  const base = 'native/terminal_core/target/release';
  if (Platform.isMacOS) return '$base/libssterm_terminal_core.dylib';
  if (Platform.isWindows) return '$base/ssterm_terminal_core.dll';
  return '$base/libssterm_terminal_core.so';
}

void main() {
  final path = _libraryPath();
  final available = File(path).existsSync();

  test(
    'Rust terminal ABI preserves split UTF-8 and emits OSC 7 state',
    () {
      final terminal = RustTerminalCore.open(
        columns: 12,
        rows: 2,
        libraryPath: path,
      );
      addTearDown(terminal.close);

      terminal.feed(Uint8List.fromList([0xe4, 0xbd]));
      final update = terminal.feed(
        Uint8List.fromList([
          0xa0,
          ...'\x1b]7;file:///workspace\x1b'.codeUnits,
          0x5c,
        ]),
      );

      expect(update.cursorColumn, 2);
      expect(update.workingDirectoryChanged, isTrue);
      expect(update.hasDirtyRows, isTrue);
      expect(terminal.rowText(0), '你');
      expect(terminal.cell(0, 0).codepoint, '你'.runes.single);
      expect(terminal.cell(0, 0).width, 2);
      expect(terminal.cell(0, 1).width, 0);

      final snapshot = RustTerminalSnapshotBuffer();
      addTearDown(snapshot.close);
      expect(terminal.snapshotInto(snapshot), 2);
      expect(snapshot.columns, 12);
      expect(snapshot.rows, 2);
      expect(snapshot.cellCount, 24);
      expect(snapshot.cursorColumn, 2);
      expect(snapshot.cursorRow, 0);
      expect(snapshot.usingAlternateScreen, isFalse);
      expect(snapshot.cell(0, 0).codepoint, '你'.runes.single);
      expect(snapshot.cell(0, 0).width, 2);
      expect(snapshot.cell(0, 1).width, 0);

      final render = RustTerminalRenderBuffer();
      addTearDown(render.close);
      expect(terminal.renderSnapshotInto(render), 2);
      expect(render.wordCount, 12 * 2 * 5);
      expect(render.rowWords(0)[3] & 0x1fffff, '你'.runes.single);
      expect(render.rowWords(0)[3] >> 22, 2);
      expect(render.rowWords(0)[8] >> 22, 0);
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'Rust core matches xterm for the supported parser fixture',
    () {
      final rust = RustTerminalCore.open(
        columns: 12,
        rows: 3,
        libraryPath: path,
      );
      addTearDown(rust.close);
      final dart = Terminal()..resize(12, 3);

      // Keep boundaries intentional: ESC/CSI/OSC and UTF-8 arrive in separate
      // PTY reads in normal use, and both engines must preserve parser state.
      final chunks = <String>[
        'hello',
        '\x1b[2;3H中',
        '\x1b[1;1H!',
        '\x1b]7;file:///workspace\x1b',
        '\\',
        '\x1b[3;1Htail',
      ];
      for (final chunk in chunks) {
        dart.write(chunk);
        rust.feed(Uint8List.fromList(utf8.encode(chunk)));
      }

      for (var row = 0; row < 3; row++) {
        expect(
          rust.rowText(row).trimLeft(),
          dart.buffer.lines[dart.buffer.scrollBack + row].toString(),
          reason: 'row $row must match the current Dart engine',
        );
        final dartLine = dart.buffer.lines[dart.buffer.scrollBack + row];
        for (var column = 0; column < 12; column++) {
          final cell = rust.cell(row, column);
          expect(cell.codepoint, dartLine.getCodePoint(column));
          expect(cell.width, dartLine.getWidth(column));
        }
      }
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'Rust core matches xterm for cursor, erase, and scroll fixtures',
    () {
      const fixtures = <List<String>>[
        ['plain text'],
        ['abc\rZ'],
        ['one\r\ntwo\r\nthree\r\nfour'],
        ['abcdef', '\x1b[1;3H!', '\x1b[2K'],
        ['abcdef', '\x1b[1;3H!', '\x1b[K'],
        ['abc', '\x1b[2J', 'z'],
        ['\x1b[3;5Hend', '\x1b[1A!', '\x1b[2D?'],
        ['12345678', '\x1b[?7l', 'X'],
        ['abcdef', '\x1b[1;3H', '\x1b[2@', 'XY'],
        ['abcdef', '\x1b[1;3H', '\x1b[2P'],
        ['abcdef', '\x1b[1;3H', '\x1b[2X'],
        ['abcdef', '\x1b[2G', 'Z'],
        ['abcdef', '\x1b[1;4H', '\x1b7', 'X', '\x1b8', '!'],
        ['one', '\x1bD', 'two', '\x1bE', 'three'],
        ['one\r\ntwo\r\nthree', '\x1b[2;3r', '\x1b[3;1H', '\n'],
        ['one\r\ntwo\r\nthree', '\x1b[2;3r', '\x1b[2;1H', '\x1b[L'],
        ['one\r\ntwo\r\nthree', '\x1b[2;3r', '\x1b[2;1H', '\x1b[M'],
        ['one\r\ntwo\r\nthree', '\x1b[3;3r', '\x1b[3;1H', '\x1b[L'],
        ['one\r\ntwo\r\nthree', '\x1b[2;3r', '\x1b[S'],
        ['one\r\ntwo\r\nthree', '\x1b[2;3r', '\x1b[T'],
        ['one\r\ntwo\r\nthree\r\nfour', '\x1b[3J'],
      ];

      for (final chunks in fixtures) {
        final rust = RustTerminalCore.open(
          columns: 8,
          rows: 3,
          libraryPath: path,
        );
        addTearDown(rust.close);
        final dart = Terminal()..resize(8, 3);
        for (final chunk in chunks) {
          dart.write(chunk);
          rust.feed(Uint8List.fromList(utf8.encode(chunk)));
        }
        for (var row = 0; row < 3; row++) {
          expect(
            rust.rowText(row).trimLeft(),
            dart.buffer.lines[dart.buffer.scrollBack + row].toString(),
            reason: 'fixture=$chunks, row=$row',
          );
          final dartLine = dart.buffer.lines[dart.buffer.scrollBack + row];
          for (var column = 0; column < 8; column++) {
            final cell = rust.cell(row, column);
            expect(
              cell.codepoint,
              dartLine.getCodePoint(column),
              reason: 'fixture=$chunks, row=$row, column=$column codepoint',
            );
            expect(
              cell.width,
              dartLine.getWidth(column),
              reason: 'fixture=$chunks, row=$row, column=$column width',
            );
          }
        }
      }
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'Rust core matches xterm SGR cell attributes and extended colors',
    () {
      final rust = RustTerminalCore.open(
        columns: 8,
        rows: 1,
        libraryPath: path,
      );
      addTearDown(rust.close);
      final dart = Terminal()..resize(8, 1);
      const input = '\x1b[1;31;48;5;123mA\x1b[0mB';
      dart.write(input);
      rust.feed(Uint8List.fromList(utf8.encode(input)));

      for (var column = 0; column < 2; column++) {
        final native = rust.cell(0, column);
        final line = dart.buffer.lines[0];
        expect(native.codepoint, line.getCodePoint(column));
        expect(native.width, line.getWidth(column));
        expect(native.foreground, line.getForeground(column));
        expect(native.background, line.getBackground(column));
        expect(native.attributes, line.getAttributes(column));
      }
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'Rust core matches xterm alternate-buffer restoration',
    () {
      final rust = RustTerminalCore.open(
        columns: 12,
        rows: 2,
        libraryPath: path,
      );
      addTearDown(rust.close);
      final dart = Terminal()..resize(12, 2);

      for (final chunk in ['shell', '\x1b[?1049h', 'editor', '\x1b[?1049l']) {
        dart.write(chunk);
        rust.feed(Uint8List.fromList(utf8.encode(chunk)));
      }

      expect(
        rust.rowText(0),
        dart.buffer.lines[dart.buffer.scrollBack].toString(),
      );
      for (var column = 0; column < 12; column++) {
        expect(
          rust.cell(0, column).codepoint,
          dart.buffer.lines[dart.buffer.scrollBack].getCodePoint(column),
        );
      }
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'Rust ABI exports modes, query responses, and scrollback deltas',
    () {
      final rust = RustTerminalCore.open(
        columns: 4,
        rows: 2,
        libraryPath: path,
        backgroundRgb: 0x123456,
      );
      addTearDown(rust.close);

      rust.feed(
        Uint8List.fromList(
          utf8.encode(
            'aa\r\nbb\r\ncc'
            '\x1b[?1h\x1b[?25l\x1b[?1006h\x1b[?2004h'
            '\x1b[?u\x1b]11;?\x07',
          ),
        ),
      );

      expect(
        utf8.decode(rust.takeResponse()),
        '\x1b[?0u\x1b]11;rgb:1212/3434/5656\x07',
      );
      expect(rust.takeResponse(), isEmpty);

      final visible = RustTerminalRenderBuffer();
      final history = RustTerminalRenderBuffer();
      addTearDown(visible.close);
      addTearDown(history.close);
      rust.renderSnapshotInto(visible);
      expect(visible.scrollbackRows, 1);
      expect(visible.scrollbackSequence, 1);
      expect(visible.modeFlags & (1 << 2), isNonZero);
      expect(visible.modeFlags & (1 << 7), 0);
      expect(visible.modeFlags & (1 << 11), isNonZero);
      expect(visible.mouseReportMode, 2);

      rust.historySnapshotInto(history, startRow: 0, rowCount: 1);
      expect(history.wordCount, 4 * 5);
      expect(history.words[3] & 0x1fffff, 'a'.codeUnitAt(0));
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test('local PTY output defaults to the Rust-authoritative render path', () {
    final localSource = File('lib/app/main_local.dart').readAsStringSync();
    final tabSource = File('lib/models/tab_model.dart').readAsStringSync();

    expect(localSource, contains("SSTERM_DART_TERMINAL_CORE'] == '1'"));
    expect(localSource, contains("SSTERM_RUST_TERMINAL_CORE'] == '0'"));
    expect(localSource, contains('terminalByteSink: rustTerminalBridge'));
    expect(localSource, isNot(contains('rustTerminalCore?.feed(')));
    expect(localSource, contains('rustTerminalBridge?.resize(w, h)'));
    expect(tabSource, contains('RustTerminalCore? rustTerminalCore'));
    expect(tabSource, contains('RustTerminalBridge? rustTerminalBridge'));
    expect(tabSource, contains('rustTerminalCore?.close()'));
  });
}
