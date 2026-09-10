import 'dart:convert';
import 'dart:io';

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
      final terminal = Terminal()..resize(4, 2);
      final core = RustTerminalCore.open(
        columns: 4,
        rows: 2,
        libraryPath: path,
      );
      final replies = <int>[];
      final bridge = RustTerminalBridge(
        core: core,
        terminal: terminal,
        onResponseBytes: replies.addAll,
      );
      addTearDown(() {
        bridge.close();
        core.close();
      });

      bridge.write(
        utf8.encode(
          'aa\r\nbb\r\ncc\r\ndd'
          '\x1b[?1h\x1b[?25l\x1b[?2004h\x1b[0c',
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
      expect(utf8.decode(replies), '\x1b[?1;2c');
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
}
