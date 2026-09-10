import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// ABI mirror for `SstermTerminalUpdate`.
final class RustTerminalUpdate extends Struct {
  @Uint32()
  external int dirtyRowStart;
  @Uint32()
  external int dirtyRowEnd;
  @Uint32()
  external int cursorColumn;
  @Uint32()
  external int cursorRow;
  @Uint32()
  external int bellCount;
  @Uint32()
  external int titleChanged;
  @Uint32()
  external int workingDirectoryChanged;
}

/// ABI mirror for `SstermTerminalCell`.
final class RustTerminalCell extends Struct {
  @Uint32()
  external int codepoint;
  @Uint32()
  external int foreground;
  @Uint32()
  external int background;
  @Uint32()
  external int attributes;
  @Uint32()
  external int underlineColor;
  @Uint8()
  external int width;
  @Array(3)
  external Array<Uint8> reserved;
}

/// ABI mirror for `SstermTerminalSnapshot`.
final class RustTerminalSnapshotMetadata extends Struct {
  @Uint32()
  external int columns;
  @Uint32()
  external int rows;
  @Uint32()
  external int scrollbackRows;
  @Uint32()
  external int cursorColumn;
  @Uint32()
  external int cursorRow;
  @Uint32()
  external int usingAlternateScreen;
  @Uint32()
  external int modeFlags;
  @Uint32()
  external int mouseMode;
  @Uint32()
  external int mouseReportMode;
  @Uint32()
  external int cursorShape;
  @Uint64()
  external int generation;
  @Uint64()
  external int scrollbackSequence;
  @Uint64()
  external int historyEpoch;
}

class RustTerminalCellValue {
  RustTerminalCellValue._(RustTerminalCell cell)
    : codepoint = cell.codepoint,
      width = cell.width,
      foreground = cell.foreground,
      background = cell.background,
      attributes = cell.attributes,
      underlineColor = cell.underlineColor;

  final int codepoint;
  final int width;
  final int foreground;
  final int background;
  final int attributes;
  final int underlineColor;
}

/// Caller-owned native screen buffer reusable across terminal frames.
///
/// Keeping this allocation outside [RustTerminalCore] permits a renderer to
/// double-buffer snapshots: Rust fills the back buffer, then Flutter swaps it
/// with the immutable front buffer without issuing one FFI call per cell.
class RustTerminalSnapshotBuffer {
  RustTerminalSnapshotBuffer({int initialCellCapacity = 0})
    : _metadata = calloc<RustTerminalSnapshotMetadata>() {
    if (initialCellCapacity > 0) {
      _grow(initialCellCapacity);
    }
  }

  final Pointer<RustTerminalSnapshotMetadata> _metadata;
  Pointer<RustTerminalCell> _cells = nullptr.cast<RustTerminalCell>();
  var _capacity = 0;
  var _cellCount = 0;
  var _closed = false;

  int get columns => _metadata.ref.columns;
  int get rows => _metadata.ref.rows;
  int get scrollbackRows => _metadata.ref.scrollbackRows;
  int get cursorColumn => _metadata.ref.cursorColumn;
  int get cursorRow => _metadata.ref.cursorRow;
  int get generation => _metadata.ref.generation;
  int get modeFlags => _metadata.ref.modeFlags;
  int get mouseMode => _metadata.ref.mouseMode;
  int get mouseReportMode => _metadata.ref.mouseReportMode;
  int get cursorShape => _metadata.ref.cursorShape;
  int get scrollbackSequence => _metadata.ref.scrollbackSequence;
  int get historyEpoch => _metadata.ref.historyEpoch;
  bool get usingAlternateScreen => _metadata.ref.usingAlternateScreen != 0;
  int get cellCount => _cellCount;

  RustTerminalCellValue cell(int row, int column) {
    _ensureOpen();
    RangeError.checkValueInInterval(row, 0, rows - 1, 'row');
    RangeError.checkValueInInterval(column, 0, columns - 1, 'column');
    return RustTerminalCellValue._(_cells[row * columns + column]);
  }

  void _ensureCapacity(int required) {
    if (required <= _capacity) return;
    var next = _capacity == 0 ? 256 : _capacity;
    while (next < required) {
      next *= 2;
    }
    _grow(next);
  }

  void _grow(int capacity) {
    final replacement = calloc<RustTerminalCell>(capacity);
    if (_cells != nullptr) calloc.free(_cells);
    _cells = replacement;
    _capacity = capacity;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Rust terminal snapshot buffer is closed.');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_cells != nullptr) calloc.free(_cells);
    calloc.free(_metadata);
  }
}

/// Reusable snapshot in the exact packed layout consumed by xterm's painter.
///
/// The native allocation is exposed as a [Uint32List], so copying one dirty
/// row into a Dart render buffer is a single typed-data operation rather than
/// thousands of FFI calls or temporary Dart cell objects.
class RustTerminalRenderBuffer {
  RustTerminalRenderBuffer({int initialWordCapacity = 0})
    : _metadata = calloc<RustTerminalSnapshotMetadata>() {
    if (initialWordCapacity > 0) _grow(initialWordCapacity);
  }

  static const wordsPerCell = 5;

  final Pointer<RustTerminalSnapshotMetadata> _metadata;
  Pointer<Uint32> _words = nullptr.cast<Uint32>();
  var _capacity = 0;
  var _wordCount = 0;
  var _closed = false;

  int get columns => _metadata.ref.columns;
  int get rows => _metadata.ref.rows;
  int get scrollbackRows => _metadata.ref.scrollbackRows;
  int get cursorColumn => _metadata.ref.cursorColumn;
  int get cursorRow => _metadata.ref.cursorRow;
  int get generation => _metadata.ref.generation;
  int get modeFlags => _metadata.ref.modeFlags;
  int get mouseMode => _metadata.ref.mouseMode;
  int get mouseReportMode => _metadata.ref.mouseReportMode;
  int get cursorShape => _metadata.ref.cursorShape;
  int get scrollbackSequence => _metadata.ref.scrollbackSequence;
  int get historyEpoch => _metadata.ref.historyEpoch;
  bool get usingAlternateScreen => _metadata.ref.usingAlternateScreen != 0;
  int get wordCount => _wordCount;
  Uint32List get words {
    _ensureOpen();
    return _words.asTypedList(_wordCount);
  }

  Uint32List rowWords(int row) {
    _ensureOpen();
    RangeError.checkValueInInterval(row, 0, rows - 1, 'row');
    final width = columns * wordsPerCell;
    return Uint32List.sublistView(words, row * width, (row + 1) * width);
  }

  void _ensureCapacity(int required) {
    if (required <= _capacity) return;
    var next = _capacity == 0 ? 1280 : _capacity;
    while (next < required) {
      next *= 2;
    }
    _grow(next);
  }

  void _grow(int capacity) {
    final replacement = calloc<Uint32>(capacity);
    if (_words != nullptr) calloc.free(_words);
    _words = replacement;
    _capacity = capacity;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Rust terminal render buffer is closed.');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_words != nullptr) calloc.free(_words);
    calloc.free(_metadata);
  }
}

/// Immutable Dart value returned after a native terminal batch is processed.
class RustTerminalCoreUpdate {
  RustTerminalCoreUpdate._(RustTerminalUpdate update)
    : dirtyRowStart = update.dirtyRowStart,
      dirtyRowEnd = update.dirtyRowEnd,
      cursorColumn = update.cursorColumn,
      cursorRow = update.cursorRow,
      bellCount = update.bellCount,
      titleChanged = update.titleChanged != 0,
      workingDirectoryChanged = update.workingDirectoryChanged != 0;

  final int dirtyRowStart;
  final int dirtyRowEnd;
  final int cursorColumn;
  final int cursorRow;
  final int bellCount;
  final bool titleChanged;
  final bool workingDirectoryChanged;

  bool get hasDirtyRows => dirtyRowStart != 0xffffffff;
}

/// Batch-oriented FFI binding for the production Rust terminal engine.
///
/// Session bytes cross FFI once per output batch. Screen cells, history,
/// modes, and protocol responses are copied through reusable caller-owned
/// buffers; the Flutter side never calls native code once per cell.
class RustTerminalCore {
  RustTerminalCore._(this._library, this._handle) {
    _destroy = _library.lookupFunction<_DestroyNative, _DestroyDart>(
      'ssterm_terminal_destroy',
    );
    _feed = _library.lookupFunction<_FeedNative, _FeedDart>(
      'ssterm_terminal_feed',
    );
    _resize = _library.lookupFunction<_ResizeNative, _ResizeDart>(
      'ssterm_terminal_resize',
    );
    _rowText = _library.lookupFunction<_RowTextNative, _RowTextDart>(
      'ssterm_terminal_row_text',
    );
    _cell = _library.lookupFunction<_CellNative, _CellDart>(
      'ssterm_terminal_cell',
    );
    _snapshot = _library.lookupFunction<_SnapshotNative, _SnapshotDart>(
      'ssterm_terminal_snapshot',
    );
    _renderSnapshot = _library
        .lookupFunction<_RenderSnapshotNative, _RenderSnapshotDart>(
          'ssterm_terminal_snapshot_xterm_cells',
        );
    _historySnapshot = _library
        .lookupFunction<_HistorySnapshotNative, _HistorySnapshotDart>(
          'ssterm_terminal_history_xterm_cells',
        );
    _takeResponse = _library
        .lookupFunction<_TakeResponseNative, _TakeResponseDart>(
          'ssterm_terminal_take_response',
        );
    _setBackgroundRgb = _library
        .lookupFunction<_SetBackgroundRgbNative, _SetBackgroundRgbDart>(
          'ssterm_terminal_set_background_rgb',
        );
    _title = _library.lookupFunction<_StringValueNative, _StringValueDart>(
      'ssterm_terminal_title',
    );
    _workingDirectory = _library
        .lookupFunction<_StringValueNative, _StringValueDart>(
          'ssterm_terminal_working_directory',
        );
  }

  final DynamicLibrary _library;
  final Pointer<Void> _handle;
  late final _DestroyDart _destroy;
  late final _FeedDart _feed;
  late final _ResizeDart _resize;
  late final _RowTextDart _rowText;
  late final _CellDart _cell;
  late final _SnapshotDart _snapshot;
  late final _RenderSnapshotDart _renderSnapshot;
  late final _HistorySnapshotDart _historySnapshot;
  late final _TakeResponseDart _takeResponse;
  late final _SetBackgroundRgbDart _setBackgroundRgb;
  late final _StringValueDart _title;
  late final _StringValueDart _workingDirectory;
  Pointer<Uint8> _inputBuffer = nullptr.cast<Uint8>();
  var _inputCapacity = 0;
  Pointer<Uint8> _responseBuffer = nullptr.cast<Uint8>();
  var _responseCapacity = 0;
  var _closed = false;

  /// Opens a native terminal core already bundled by the host application.
  /// Tests may pass the absolute path of Cargo's built dynamic library.
  factory RustTerminalCore.open({
    required int columns,
    required int rows,
    int maxScrollbackRows = 1000,
    int backgroundRgb = 0x1e1e1e,
    String? libraryPath,
  }) {
    final library = DynamicLibrary.open(libraryPath ?? _bundledLibraryPath());
    final create = library
        .lookupFunction<_CreateWithScrollbackNative, _CreateWithScrollbackDart>(
          'ssterm_terminal_create_with_scrollback',
        );
    final handle = create(columns, rows, maxScrollbackRows);
    if (handle == nullptr) {
      throw StateError('Rust terminal core failed to allocate its screen.');
    }
    final core = RustTerminalCore._(library, handle);
    core._setBackgroundRgb(handle, backgroundRgb);
    return core;
  }

  RustTerminalCoreUpdate feed(Uint8List bytes) {
    _ensureOpen();
    if (bytes.isNotEmpty) {
      _ensureInputCapacity(bytes.length);
      _inputBuffer.asTypedList(bytes.length).setAll(0, bytes);
    }
    return RustTerminalCoreUpdate._(_feed(_handle, _inputBuffer, bytes.length));
  }

  /// Copies the current visible grid into a reusable caller-owned buffer.
  /// Returns the snapshot generation written to [destination].
  int snapshotInto(RustTerminalSnapshotBuffer destination) {
    _ensureOpen();
    destination._ensureOpen();
    var required = _snapshot(
      _handle,
      destination._metadata,
      destination._cells,
      destination._capacity,
    );
    if (required > destination._capacity) {
      destination._ensureCapacity(required);
      required = _snapshot(
        _handle,
        destination._metadata,
        destination._cells,
        destination._capacity,
      );
    }
    destination._cellCount = required;
    return destination.generation;
  }

  int renderSnapshotInto(RustTerminalRenderBuffer destination) {
    _ensureOpen();
    destination._ensureOpen();
    var required = _renderSnapshot(
      _handle,
      destination._metadata,
      destination._words,
      destination._capacity,
    );
    if (required > destination._capacity) {
      destination._ensureCapacity(required);
      required = _renderSnapshot(
        _handle,
        destination._metadata,
        destination._words,
        destination._capacity,
      );
    }
    destination._wordCount = required;
    return destination.generation;
  }

  int historySnapshotInto(
    RustTerminalRenderBuffer destination, {
    required int startRow,
    required int rowCount,
  }) {
    _ensureOpen();
    destination._ensureOpen();
    var required = _historySnapshot(
      _handle,
      startRow,
      rowCount,
      destination._words,
      destination._capacity,
    );
    if (required > destination._capacity) {
      destination._ensureCapacity(required);
      required = _historySnapshot(
        _handle,
        startRow,
        rowCount,
        destination._words,
        destination._capacity,
      );
    }
    destination._wordCount = required;
    return required;
  }

  Uint8List takeResponse() {
    _ensureOpen();
    var required = _takeResponse(_handle, _responseBuffer, _responseCapacity);
    if (required == 0) return Uint8List(0);
    if (required > _responseCapacity) {
      if (_responseBuffer != nullptr) calloc.free(_responseBuffer);
      _responseBuffer = calloc<Uint8>(required);
      _responseCapacity = required;
      required = _takeResponse(_handle, _responseBuffer, _responseCapacity);
    }
    return Uint8List.fromList(_responseBuffer.asTypedList(required));
  }

  String get title {
    _ensureOpen();
    final value = _title(_handle);
    return value == nullptr ? '' : value.toDartString();
  }

  String get workingDirectory {
    _ensureOpen();
    final value = _workingDirectory(_handle);
    return value == nullptr ? '' : value.toDartString();
  }

  void _ensureInputCapacity(int required) {
    if (required <= _inputCapacity) return;
    var next = _inputCapacity == 0 ? 4096 : _inputCapacity;
    while (next < required) {
      next *= 2;
    }
    final replacement = calloc<Uint8>(next);
    if (_inputBuffer != nullptr) calloc.free(_inputBuffer);
    if (_responseBuffer != nullptr) calloc.free(_responseBuffer);
    _inputBuffer = replacement;
    _inputCapacity = next;
  }

  void resize(int columns, int rows) {
    _ensureOpen();
    _resize(_handle, columns, rows);
  }

  /// Returns the UTF-8 text rendered on a visible row. The fixture parity
  /// harness uses this while the eventual Flutter renderer consumes native
  /// cells and dirty rectangles directly.
  String rowText(int row) {
    _ensureOpen();
    final needed = _rowText(_handle, row, nullptr.cast(), 0);
    if (needed == 0) return '';
    final output = calloc<Uint8>(needed + 1);
    try {
      final written = _rowText(_handle, row, output.cast(), needed + 1);
      if (written != needed) {
        throw StateError(
          'Rust terminal core returned an inconsistent row size.',
        );
      }
      return output.cast<Utf8>().toDartString();
    } finally {
      calloc.free(output);
    }
  }

  RustTerminalCellValue cell(int row, int column) {
    _ensureOpen();
    return RustTerminalCellValue._(_cell(_handle, row, column));
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_inputBuffer != nullptr) calloc.free(_inputBuffer);
    _destroy(_handle);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Rust terminal core is closed.');
    }
  }

  static String _libraryFileName() {
    if (Platform.isMacOS || Platform.isIOS) {
      return 'libssterm_terminal_core.dylib';
    }
    if (Platform.isWindows) {
      return 'ssterm_terminal_core.dll';
    }
    return 'libssterm_terminal_core.so';
  }

  static String _bundledLibraryPath() {
    final filename = _libraryFileName();
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS || Platform.isWindows) {
      final besideExecutable = File('${executableDirectory.path}/$filename');
      if (besideExecutable.existsSync()) return besideExecutable.path;
    } else if (Platform.isLinux) {
      final inBundleLib = File(
        '${executableDirectory.parent.path}/lib/$filename',
      );
      if (inBundleLib.existsSync()) return inBundleLib.path;
    }
    // Keeps command-line and development invocation working when the library
    // is supplied through the platform loader rather than an app bundle.
    return filename;
  }
}

typedef _CreateWithScrollbackNative =
    Pointer<Void> Function(
      Uint32 columns,
      Uint32 rows,
      Uint32 maxScrollbackRows,
    );
typedef _CreateWithScrollbackDart =
    Pointer<Void> Function(int columns, int rows, int maxScrollbackRows);
typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);
typedef _FeedNative =
    RustTerminalUpdate Function(
      Pointer<Void> handle,
      Pointer<Uint8> bytes,
      IntPtr length,
    );
typedef _FeedDart =
    RustTerminalUpdate Function(
      Pointer<Void> handle,
      Pointer<Uint8> bytes,
      int length,
    );
typedef _ResizeNative =
    Void Function(Pointer<Void> handle, Uint32 columns, Uint32 rows);
typedef _ResizeDart =
    void Function(Pointer<Void> handle, int columns, int rows);
typedef _RowTextNative =
    IntPtr Function(
      Pointer<Void> handle,
      Uint32 row,
      Pointer<Int8> destination,
      IntPtr destinationLength,
    );
typedef _RowTextDart =
    int Function(
      Pointer<Void> handle,
      int row,
      Pointer<Int8> destination,
      int destinationLength,
    );
typedef _CellNative =
    RustTerminalCell Function(Pointer<Void> handle, Uint32 row, Uint32 column);
typedef _CellDart =
    RustTerminalCell Function(Pointer<Void> handle, int row, int column);
typedef _SnapshotNative =
    IntPtr Function(
      Pointer<Void> handle,
      Pointer<RustTerminalSnapshotMetadata> metadata,
      Pointer<RustTerminalCell> destination,
      IntPtr destinationCapacity,
    );
typedef _SnapshotDart =
    int Function(
      Pointer<Void> handle,
      Pointer<RustTerminalSnapshotMetadata> metadata,
      Pointer<RustTerminalCell> destination,
      int destinationCapacity,
    );
typedef _RenderSnapshotNative =
    IntPtr Function(
      Pointer<Void> handle,
      Pointer<RustTerminalSnapshotMetadata> metadata,
      Pointer<Uint32> destination,
      IntPtr destinationWordCapacity,
    );
typedef _RenderSnapshotDart =
    int Function(
      Pointer<Void> handle,
      Pointer<RustTerminalSnapshotMetadata> metadata,
      Pointer<Uint32> destination,
      int destinationWordCapacity,
    );
typedef _HistorySnapshotNative =
    IntPtr Function(
      Pointer<Void> handle,
      Uint32 startRow,
      Uint32 rowCount,
      Pointer<Uint32> destination,
      IntPtr destinationWordCapacity,
    );
typedef _HistorySnapshotDart =
    int Function(
      Pointer<Void> handle,
      int startRow,
      int rowCount,
      Pointer<Uint32> destination,
      int destinationWordCapacity,
    );
typedef _TakeResponseNative =
    IntPtr Function(
      Pointer<Void> handle,
      Pointer<Uint8> destination,
      IntPtr destinationCapacity,
    );
typedef _TakeResponseDart =
    int Function(
      Pointer<Void> handle,
      Pointer<Uint8> destination,
      int destinationCapacity,
    );
typedef _SetBackgroundRgbNative =
    Void Function(Pointer<Void> handle, Uint32 rgb);
typedef _SetBackgroundRgbDart = void Function(Pointer<Void> handle, int rgb);
typedef _StringValueNative = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _StringValueDart = Pointer<Utf8> Function(Pointer<Void> handle);
