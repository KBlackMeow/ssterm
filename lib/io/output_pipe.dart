import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

/// Minimal interface for session logging.
/// [SessionLogger] implements this structurally; cast as needed.
abstract interface class LogSink {
  void write(List<int> bytes);
  Future<void> close();
}

/// Bridges one or more `Stream<List<int>>` sources to a [Terminal].
///
/// Chunks are buffered for [_kFlushInterval] before each write so the main
/// thread is not blocked on rapid small writes (e.g. shell startup bursts).
/// Writes larger than [_kMaxBytesPerWrite] are split across multiple ticks so
/// the UI stays responsive during large output floods.
class OutputPipe {
  OutputPipe(
    this._terminal, {
    this.transform,
    this.logSink,
  });

  final Terminal _terminal;
  final List<int> Function(List<int>)? transform;
  final LogSink? logSink;

  final _buf = BytesBuilder(copy: false);
  Timer? _timer;
  final _subs = <StreamSubscription<List<int>>>[];

  static const _kMaxBytesPerWrite = 65536; // 64 KB
  static const _kFlushInterval = Duration(milliseconds: 16); // ~60 fps

  void bind(Stream<List<int>> stream) {
    _subs.add(stream.listen(_onChunk));
  }

  void _onChunk(List<int> chunk) {
    _buf.add(chunk);
    _timer ??= Timer(_kFlushInterval, _flush);
  }

  void _flush() {
    _timer = null;
    final all = _buf.takeBytes();
    if (all.isEmpty) return;

    final Uint8List toWrite;
    if (all.length > _kMaxBytesPerWrite) {
      toWrite = Uint8List.sublistView(all, 0, _kMaxBytesPerWrite);
      _buf.add(Uint8List.sublistView(all, _kMaxBytesPerWrite));
      _timer = Timer(_kFlushInterval, _flush);
    } else {
      toWrite = all;
    }

    logSink?.write(toWrite);

    List<int> out = toWrite;
    if (transform != null) {
      out = Uint8List.fromList(transform!(toWrite));
    }
    if (out.isNotEmpty) {
      _terminal.write(utf8.decode(out, allowMalformed: true));
    }
  }

  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    logSink?.close();
  }
}
