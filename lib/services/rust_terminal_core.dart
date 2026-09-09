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

/// A small, explicit FFI binding for the Rust terminal engine.
///
/// It is intentionally not wired into the production [Terminal] yet: the
/// Dart xterm engine remains authoritative until the full VT fixture parity
/// gate is passed. Keeping this binding separate lets integration tests use
/// the exact release ABI without a second parser implementation in Dart.
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
  }

  final DynamicLibrary _library;
  final Pointer<Void> _handle;
  late final _DestroyDart _destroy;
  late final _FeedDart _feed;
  late final _ResizeDart _resize;
  late final _RowTextDart _rowText;
  late final _CellDart _cell;
  var _closed = false;

  /// Opens a native terminal core already bundled by the host application.
  /// Tests may pass the absolute path of Cargo's built dynamic library.
  factory RustTerminalCore.open({
    required int columns,
    required int rows,
    int maxScrollbackRows = 1000,
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
    return RustTerminalCore._(library, handle);
  }

  RustTerminalCoreUpdate feed(Uint8List bytes) {
    _ensureOpen();
    // Dart does not expose a stable address for a managed Uint8List. Copying
    // into short-lived native storage is safe across all supported runtimes;
    // the production bridge will use a reusable native ring buffer to avoid
    // this copy after the engine switch is enabled.
    final Pointer<Uint8> nativeBytes = bytes.isEmpty
        ? nullptr.cast<Uint8>()
        : calloc<Uint8>(bytes.length);
    try {
      if (bytes.isNotEmpty) {
        nativeBytes.asTypedList(bytes.length).setAll(0, bytes);
      }
      return RustTerminalCoreUpdate._(
        _feed(_handle, nativeBytes, bytes.length),
      );
    } finally {
      if (nativeBytes != nullptr) {
        calloc.free(nativeBytes);
      }
    }
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
