import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/rust_terminal_core.dart';
import 'package:xterm/xterm.dart';
import 'package:xterm/src/utils/unicode_v11.dart' show isExtendedPictographic;

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
    'incremental snapshots equal full rebuilds after resize and buffer reuse',
    () {
      expect(
        DynamicLibrary.open(
          path,
        ).providesSymbol('ssterm_terminal_snapshot_xterm_cells_incremental'),
        isTrue,
        reason: 'Rebuild the native library to exercise the incremental ABI',
      );
      final core = RustTerminalCore.open(
        columns: 12,
        rows: 4,
        libraryPath: path,
      );
      final other = RustTerminalCore.open(
        columns: 12,
        rows: 4,
        libraryPath: path,
      );
      final retained = RustTerminalRenderBuffer();
      final rebuilt = RustTerminalRenderBuffer();
      addTearDown(() {
        retained.close();
        rebuilt.close();
        core.close();
        other.close();
      });
      void compare() {
        core.renderSnapshotInto(retained);
        core.renderSnapshotInto(rebuilt, incremental: false);
        expect(retained.words, orderedEquals(rebuilt.words));
        expect(retained.columns, rebuilt.columns);
        expect(retained.rows, rebuilt.rows);
        expect(retained.cursorColumn, rebuilt.cursorColumn);
        expect(retained.cursorRow, rebuilt.cursorRow);
        expect(retained.modeFlags, rebuilt.modeFlags);
      }

      compare();
      for (final text in [
        'old\r\nsecond',
        '\x1b[H\x1b[2K',
        '中😀',
        '\x1b[?1049hALT',
        '\x1b[?1049l',
        '\x1b[2J',
      ]) {
        core.feed(Uint8List.fromList(utf8.encode(text)));
        compare();
      }
      for (final size in [(80, 24), (9, 3), (12, 4), (12, 2), (12, 8)]) {
        core.resize(size.$1, size.$2);
        compare();
      }
      core.resize(12, 4);
      compare();
      other.feed(Uint8List.fromList(utf8.encode('other terminal')));
      other.renderSnapshotInto(retained);
      compare(); // The buffer must not acknowledge another core's revisions.
      core.feed(
        Uint8List.fromList(utf8.encode('one\r\ntwo\r\nthree\r\nfour\r\nfive')),
      );
      compare();
      core.historySnapshotInto(retained, startRow: 0, rowCount: 1);
      compare(); // A history snapshot overwrites the same retained allocation.
      core.renderSnapshotInto(retained, incremental: false);
      compare();
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'native and Dart widths agree for every Unicode scalar and width setting',
    () {
      final nativeWidth = DynamicLibrary.open(path)
          .lookupFunction<
            Uint32 Function(Uint32, Uint32, Uint32),
            int Function(int, int, int)
          >('ssterm_terminal_codepoint_width');

      for (final profile in WidthProfile.values) {
        for (final ambiguous in [false, true]) {
          final policy = TerminalWidthPolicy(
            profile: profile,
            ambiguousDoubleWidth: ambiguous,
          );
          final nativeProfile = profile == WidthProfile.legacy ? 1 : 0;
          for (var codePoint = 0; codePoint <= 0x10ffff; codePoint++) {
            if (codePoint >= 0xd800 && codePoint <= 0xdfff) continue;
            final expected = policy.widthOf(codePoint);
            final actual = nativeWidth(
              codePoint,
              nativeProfile,
              ambiguous ? 1 : 0,
            );
            if (actual != expected) {
              fail(
                'U+${codePoint.toRadixString(16)} $profile '
                'ambiguous=$ambiguous: Dart=$expected Rust=$actual',
              );
            }
          }
        }
      }
      expect(nativeWidth(0xd800, 0, 0), 0xffffffff);
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'native and Dart variation selectors agree for every pictographic base',
    () {
      final dart = Terminal()..resize(8, 1);
      final rust = RustTerminalCore.open(
        columns: 8,
        rows: 1,
        maxScrollbackRows: 0,
        libraryPath: path,
      );
      addTearDown(rust.close);

      for (var codePoint = 0; codePoint <= 0x10ffff; codePoint++) {
        if (!isExtendedPictographic(codePoint)) continue;
        for (final selector in ['\u{fe0e}', '\u{fe0f}']) {
          final text = '\r\x1b[2K${String.fromCharCode(codePoint)}${selector}X';
          dart.write(text);
          rust.feed(Uint8List.fromList(utf8.encode(text)));
          final line = dart.buffer.lines[dart.buffer.scrollBack];
          for (var col = 0; col < 8; col++) {
            final cell = rust.cell(0, col);
            if (cell.codepoint != line.getCodePoint(col) ||
                cell.width != line.getWidth(col)) {
              fail(
                'U+${codePoint.toRadixString(16)} selector '
                'U+${selector.runes.single.toRadixString(16)} col $col: '
                'Dart=${line.getCodePoint(col)}/${line.getWidth(col)} '
                'Rust=${cell.codepoint}/${cell.width}',
              );
            }
          }
        }
      }
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'native width table and variation selectors match xterm',
    () {
      const samples = ['⏸', '⏭', '✔', '✉', '※', '你', '😀', '𠀀'];
      for (final profile in WidthProfile.values) {
        for (final ambiguous in [false, true]) {
          for (final sample in samples) {
            final policy = TerminalWidthPolicy(
              profile: profile,
              ambiguousDoubleWidth: ambiguous,
            );
            final dart = Terminal(widthPolicy: policy)..resize(8, 1);
            final rust = RustTerminalCore.open(
              columns: 8,
              rows: 1,
              maxScrollbackRows: 0,
              libraryPath: path,
            );
            try {
              rust.setWidthPolicy(
                legacy: profile == WidthProfile.legacy,
                ambiguousDoubleWidth: ambiguous,
              );
              final text = '$sample X';
              dart.write(text);
              rust.feed(Uint8List.fromList(utf8.encode(text)));
              for (var col = 0; col < 8; col++) {
                expect(
                  rust.cell(0, col).width,
                  dart.buffer.lines[0].getWidth(col),
                  reason:
                      '$sample / $profile / ambiguous=$ambiguous / col=$col',
                );
                expect(
                  rust.cell(0, col).codepoint,
                  dart.buffer.lines[0].getCodePoint(col),
                );
              }
            } finally {
              rust.close();
            }
          }
        }
      }

      for (final text in ['⏸\u{fe0f}X', '✔\u{fe0e}X']) {
        final dart = Terminal()..resize(8, 1);
        final rust = RustTerminalCore.open(
          columns: 8,
          rows: 1,
          maxScrollbackRows: 0,
          libraryPath: path,
        );
        try {
          dart.write(text);
          rust.feed(Uint8List.fromList(utf8.encode(text)));
          for (var col = 0; col < 8; col++) {
            expect(
              rust.cell(0, col).width,
              dart.buffer.lines[0].getWidth(col),
              reason: '$text / col=$col',
            );
            expect(
              rust.cell(0, col).codepoint,
              dart.buffer.lines[0].getCodePoint(col),
            );
          }
        } finally {
          rust.close();
        }
      }
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

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
            '\x1b[?1h\x1b[?25l\x1b[?1006;1000h\x1b[?2004h'
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
      expect(visible.mouseMode, 2);
      expect(visible.mouseReportMode, 2);

      rust.historySnapshotInto(history, startRow: 0, rowCount: 1);
      expect(history.wordCount, 4 * 5);
      expect(history.words[3] & 0x1fffff, 'a'.codeUnitAt(0));
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'growing the PTY input buffer preserves the independent response buffer',
    () {
      final rust = RustTerminalCore.open(
        columns: 80,
        rows: 24,
        libraryPath: path,
      );
      addTearDown(rust.close);

      rust.feed(Uint8List.fromList('\x1b[?u'.codeUnits));
      expect(utf8.decode(rust.takeResponse()), '\x1b[?0u');

      // Codex can emit large frames after querying terminal capabilities.
      // Input growth must not free the reusable response allocation.
      rust.feed(Uint8List.fromList(List.filled(8192, 0x78)));
      rust.feed(Uint8List.fromList('\x1b[?u'.codeUnits));
      expect(utf8.decode(rust.takeResponse()), '\x1b[?0u');

      rust.feed(Uint8List.fromList(List.filled(16384, 0x79)));
      rust.feed(Uint8List.fromList('\x1b[?u'.codeUnits));
      expect(utf8.decode(rust.takeResponse()), '\x1b[?0u');
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'OSC 10 queries answer with the configured foreground color',
    () {
      final rust = RustTerminalCore.open(
        columns: 10,
        rows: 2,
        backgroundRgb: 0x123456,
        foregroundRgb: 0xaabbcc,
        libraryPath: path,
      );
      addTearDown(rust.close);

      rust.feed(Uint8List.fromList(utf8.encode('\x1b]10;?\x1b\\')));
      rust.feed(Uint8List.fromList(utf8.encode('\x1b[c')));

      expect(
        utf8.decode(rust.takeResponse()),
        '\x1b]10;rgb:aaaa/bbbb/cccc\x1b\\'
        '\x1b[?1;2c',
      );
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test('local PTY output has no Dart parser fallback', () {
    final localSource = File('lib/app/main_local.dart').readAsStringSync();
    final tabSource = File('lib/models/tab_model.dart').readAsStringSync();

    expect(localSource, contains('RustTerminalCore _openRustTerminalCore'));
    expect(localSource, contains('RustTerminalBridge _openRustTerminalBridge'));
    expect(localSource, isNot(contains('SSTERM_DART_TERMINAL_CORE')));
    expect(localSource, isNot(contains('SSTERM_RUST_TERMINAL_CORE')));
    expect(localSource, contains('terminalByteSink: rustTerminalBridge'));
    expect(localSource, isNot(contains('rustTerminalCore?.feed(')));
    expect(localSource, contains('rustTerminalBridge?.resize(w, h)'));
    expect(tabSource, contains('RustTerminalCore? rustTerminalCore'));
    expect(tabSource, contains('RustTerminalBridge? rustTerminalBridge'));
    expect(tabSource, contains('rustTerminalCore?.close()'));
  });
}
