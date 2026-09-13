import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/rust_terminal_bridge.dart';
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
    'bridge makes Rust screen, history, modes, and replies authoritative',
    () {
      final mouseReports = <String>[];
      final terminal = Terminal(onOutput: mouseReports.add)..resize(4, 2);
      final core = RustTerminalCore.open(
        columns: 4,
        rows: 2,
        libraryPath: path,
      );
      final replies = <int>[];
      final workingDirectories = <String>[];
      final bridge = RustTerminalBridge(
        core: core,
        terminal: terminal,
        onResponseBytes: replies.addAll,
        onWorkingDirectoryChange: workingDirectories.add,
      );
      addTearDown(() {
        bridge.close();
        core.close();
      });

      bridge.write(
        utf8.encode(
          'aa\r\nbb\r\ncc\r\ndd'
          '\x1b]7;file:///tmp\x07'
          '\x1b[?1h\x1b[?25l\x1b[?1006;1000h\x1b[?2004h\x1b[0c',
        ),
      );

      expect(terminal.mainBuffer.scrollBack, 2);
      expect(terminal.mainBuffer.lines[0].toString(), 'aa');
      expect(terminal.mainBuffer.lines[1].toString(), 'bb');
      expect(terminal.mainBuffer.lines[2].toString(), 'cc');
      expect(terminal.mainBuffer.lines[3].toString(), 'dd');
      expect(terminal.cursorKeysMode, isTrue);
      expect(terminal.cursorVisibleMode, isFalse);
      expect(terminal.bracketedPasteMode, isTrue);
      expect(terminal.mouseMode, MouseMode.upDownScroll);
      expect(terminal.mouseReportMode, MouseReportMode.sgr);
      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        const CellOffset(1, 1),
      );
      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        const CellOffset(1, 1),
      );
      expect(mouseReports, ['\x1b[<0;2;2M', '\x1b[<0;2;2m']);
      expect(utf8.decode(replies), '\x1b[?1;2c');
      expect(workingDirectories, ['/tmp']);
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'bridge reconciles layout races before importing native rows',
    () {
      final terminal = Terminal()..resize(4, 2);
      final core = RustTerminalCore.open(
        columns: 4,
        rows: 2,
        libraryPath: path,
      );
      final bridge = RustTerminalBridge(core: core, terminal: terminal);
      addTearDown(() {
        bridge.close();
        core.close();
      });

      // Simulates Flutter layout changing after the PTY/core was created but
      // before that pane's onResize callback was installed.
      terminal.resize(7, 3);
      expect(() => bridge.write(utf8.encode('ready')), returnsNormally);
      expect(
        terminal.buffer.lines[terminal.buffer.lines.length - 1].toString(),
        isNot(contains('ready')),
      );
      expect(terminal.buffer.lines[0].toString(), contains('ready'));
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  test(
    'bridge publishes synchronized output as one complete frame',
    () {
      final terminal = Terminal()..resize(4, 2);
      final core = RustTerminalCore.open(
        columns: 4,
        rows: 2,
        libraryPath: path,
      );
      final bridge = RustTerminalBridge(core: core, terminal: terminal);
      addTearDown(() {
        bridge.close();
        core.close();
      });

      bridge.write(utf8.encode('\x1b[?2026hA'));
      expect(terminal.buffer.lines[0].toString(), isEmpty);

      bridge.write(utf8.encode('\x1b[?2026l'));
      expect(terminal.buffer.lines[0].toString(), 'A');
    },
    skip: available ? false : 'run cargo build --release before this ABI test',
  );

  testWidgets('bridge defers a resize publish until after terminal layout', (
    tester,
  ) async {
    final terminal = Terminal();
    final core = RustTerminalCore.open(
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
      libraryPath: path,
    );
    final bridge = RustTerminalBridge(core: core, terminal: terminal);
    addTearDown(() {
      bridge.close();
      core.close();
    });
    terminal.onResize = (columns, rows, _, _) => bridge.resize(columns, rows);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(width: 480, height: 320, child: TerminalView(terminal)),
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.pump();
    expect(tester.takeException(), isNull);
  }, skip: !available);

  testWidgets('bridge preserves text through a split-width round trip', (
    tester,
  ) async {
    final terminal = Terminal()..resize(8, 2);
    final core = RustTerminalCore.open(columns: 8, rows: 2, libraryPath: path);
    final bridge = RustTerminalBridge(core: core, terminal: terminal);
    addTearDown(() {
      bridge.close();
      core.close();
    });
    terminal.onResize = (columns, rows, _, _) => bridge.resize(columns, rows);

    bridge.write(utf8.encode('abcdefgh'));
    terminal.resize(4, 2);
    await tester.pump();
    expect(terminal.buffer.lines[0].toString(), 'abcd');
    expect(terminal.buffer.lines[1].toString(), 'efgh');

    terminal.resize(8, 2);
    await tester.pump();
    expect(terminal.buffer.lines[0].toString(), 'abcdefgh');
    expect(terminal.buffer.lines[1].toString(), '');
  }, skip: !available);

  testWidgets('bridge does not add blank lines for a bottom-dock resize', (
    tester,
  ) async {
    final terminal = Terminal()..resize(4, 4);
    final core = RustTerminalCore.open(columns: 4, rows: 4, libraryPath: path);
    final bridge = RustTerminalBridge(core: core, terminal: terminal);
    addTearDown(() {
      bridge.close();
      core.close();
    });
    terminal.onResize = (columns, rows, _, _) => bridge.resize(columns, rows);

    bridge.write(utf8.encode('top'));
    terminal.resize(4, 2);
    await tester.pump();
    expect(terminal.buffer.lines[0].toString(), 'top');
    expect(terminal.buffer.lines[1].toString(), '');

    terminal.resize(4, 4);
    await tester.pump();
    expect(terminal.buffer.lines[0].toString(), 'top');
  }, skip: !available);
}
