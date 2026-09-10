import 'dart:async';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

import '../io/output_pipe.dart';
import 'rust_terminal_core.dart';

/// Makes the Rust parser/screen model authoritative while retaining xterm's
/// mature Flutter input, selection, and painting surfaces.
///
/// Incoming bytes are parsed exactly once by Rust. A packed snapshot is then
/// copied into the existing painter model in row-sized typed-data operations;
/// no Dart escape parsing or per-cell FFI calls occur on this path.
class RustTerminalBridge implements TerminalByteSink {
  RustTerminalBridge({
    required this.core,
    required this.terminal,
    this.onResponseBytes,
  }) : _renderBuffer = RustTerminalRenderBuffer(
         initialWordCapacity:
             terminal.viewWidth *
             terminal.viewHeight *
             RustTerminalRenderBuffer.wordsPerCell,
       ),
       _historyBuffer = RustTerminalRenderBuffer(),
       _columns = terminal.viewWidth,
       _rows = terminal.viewHeight;

  final RustTerminalCore core;
  final Terminal terminal;
  final void Function(Uint8List bytes)? onResponseBytes;
  final RustTerminalRenderBuffer _renderBuffer;
  final RustTerminalRenderBuffer _historyBuffer;
  var _closed = false;
  int _columns;
  int _rows;
  int? _historyEpoch;
  var _scrollbackSequence = 0;
  var _previousCursorRow = 0;
  Timer? _historyRebuildTimer;

  static const _maxImmediateHistoryRows = 256;
  static const _historyRebuildDelay = Duration(milliseconds: 80);

  static const _modeInsert = 1 << 0;
  static const _modeLineFeed = 1 << 1;
  static const _modeCursorKeys = 1 << 2;
  static const _modeReverseDisplay = 1 << 3;
  static const _modeOrigin = 1 << 4;
  static const _modeAutoWrap = 1 << 5;
  static const _modeCursorBlink = 1 << 6;
  static const _modeCursorVisible = 1 << 7;
  static const _modeAppKeypad = 1 << 8;
  static const _modeReportFocus = 1 << 9;
  static const _modeAltMouseScroll = 1 << 10;
  static const _modeBracketedPaste = 1 << 11;

  @override
  void write(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    _resizeCoreToTerminalIfNeeded();
    final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final update = core.feed(input);
    final response = core.takeResponse();
    if (response.isNotEmpty) onResponseBytes?.call(response);
    if (update.bellCount != 0) {
      for (var index = 0; index < update.bellCount; index++) {
        terminal.onBell?.call();
      }
    }
    if (update.titleChanged) terminal.onTitleChange?.call(core.title);
    _publish(update);
  }

  void _publish(
    RustTerminalCoreUpdate? update, {
    bool forceHistoryRebuild = false,
  }) {
    _resizeCoreToTerminalIfNeeded();
    core.renderSnapshotInto(_renderBuffer);
    final historyRebuilt = _syncHistory(forceRebuild: forceHistoryRebuild);
    _syncModes();
    final cursorRow = _renderBuffer.cursorRow;
    final dirtyStart = historyRebuilt
        ? 0
        : update?.hasDirtyRows == true
        ? update!.dirtyRowStart
        : (_previousCursorRow < cursorRow ? _previousCursorRow : cursorRow);
    final dirtyEnd = historyRebuilt
        ? _renderBuffer.rows - 1
        : update?.hasDirtyRows == true
        ? update!.dirtyRowEnd
        : (_previousCursorRow > cursorRow ? _previousCursorRow : cursorRow);
    terminal.applyPackedScreen(
      packedCells: _renderBuffer.words,
      columns: _renderBuffer.columns,
      rows: _renderBuffer.rows,
      cursorColumn: _renderBuffer.cursorColumn,
      cursorRow: _renderBuffer.cursorRow,
      usingAlternateScreen: _renderBuffer.usingAlternateScreen,
      dirtyRowStart: dirtyStart,
      dirtyRowEnd: dirtyEnd,
    );
    _previousCursorRow = cursorRow;
  }

  bool _syncHistory({bool forceRebuild = false}) {
    if (_renderBuffer.usingAlternateScreen) return false;
    final epoch = _renderBuffer.historyEpoch;
    final sequence = _renderBuffer.scrollbackSequence;
    final retained = _renderBuffer.scrollbackRows;
    final delta = sequence - _scrollbackSequence;
    final replace = _historyEpoch != epoch || delta < 0 || delta > retained;
    final rows = replace ? retained : delta;
    if (!forceRebuild && rows > _maxImmediateHistoryRows) {
      _historyRebuildTimer?.cancel();
      _historyRebuildTimer = Timer(_historyRebuildDelay, () {
        _historyRebuildTimer = null;
        if (!_closed) _publish(null, forceHistoryRebuild: true);
      });
      return false;
    }
    if (rows > 0) {
      core.historySnapshotInto(
        _historyBuffer,
        startRow: replace ? 0 : retained - rows,
        rowCount: rows,
      );
      terminal.applyPackedHistory(
        packedRows: _historyBuffer.words,
        columns: _renderBuffer.columns,
        rowCount: rows,
        replace: replace,
      );
    } else if (replace) {
      terminal.applyPackedHistory(
        packedRows: Uint32List(0),
        columns: _renderBuffer.columns,
        rowCount: 0,
        replace: true,
      );
    }
    _historyEpoch = epoch;
    _scrollbackSequence = sequence;
    _historyRebuildTimer?.cancel();
    _historyRebuildTimer = null;
    return replace;
  }

  void _syncModes() {
    final flags = _renderBuffer.modeFlags;
    terminal.applyExternalModes(
      insertMode: flags & _modeInsert != 0,
      lineFeedMode: flags & _modeLineFeed != 0,
      cursorKeysMode: flags & _modeCursorKeys != 0,
      reverseDisplayMode: flags & _modeReverseDisplay != 0,
      originMode: flags & _modeOrigin != 0,
      autoWrapMode: flags & _modeAutoWrap != 0,
      mouseMode:
          MouseMode.values[_renderBuffer.mouseMode.clamp(
            0,
            MouseMode.values.length - 1,
          )],
      mouseReportMode:
          MouseReportMode.values[_renderBuffer.mouseReportMode.clamp(
            0,
            MouseReportMode.values.length - 1,
          )],
      cursorBlinkMode: flags & _modeCursorBlink != 0,
      cursorVisibleMode: flags & _modeCursorVisible != 0,
      appKeypadMode: flags & _modeAppKeypad != 0,
      reportFocusMode: flags & _modeReportFocus != 0,
      altBufferMouseScrollMode: flags & _modeAltMouseScroll != 0,
      bracketedPasteMode: flags & _modeBracketedPaste != 0,
      cursorShape: _renderBuffer.cursorShape,
    );
  }

  void resize(int columns, int rows) {
    if (_closed) return;
    if (columns < 1 || rows < 1) return;
    if (_columns == columns && _rows == rows) return;
    core.resize(columns, rows);
    _columns = columns;
    _rows = rows;
    _publish(null);
  }

  void _resizeCoreToTerminalIfNeeded() {
    final columns = terminal.viewWidth;
    final rows = terminal.viewHeight;
    if (columns < 1 || rows < 1 || (_columns == columns && _rows == rows)) {
      return;
    }
    core.resize(columns, rows);
    _columns = columns;
    _rows = rows;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _historyRebuildTimer?.cancel();
    _renderBuffer.close();
    _historyBuffer.close();
  }
}
