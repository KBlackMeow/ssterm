import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

import 'output_pipe_metrics.dart';

/// Minimal interface for session logging.
/// [SessionLogger] implements this structurally; cast as needed.
abstract interface class LogSink {
  void write(List<int> bytes);
  Future<void> close();
}

/// The result of one agent command executed in a background process.
class CommandResult {
  /// Decoded process output. Always non-null but may be empty.
  final String output;

  /// Process exit code, or null when execution did not start or finish.
  final int? exitCode;

  /// True iff [output] was clipped by the background command executor.
  final bool truncated;

  /// True iff the caller cancelled this command before it completed.
  final bool cancelled;

  CommandResult({
    required this.output,
    required this.exitCode,
    this.truncated = false,
    this.cancelled = false,
  });
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
    this.onBytesConsumed,
    this.onBytesAccepted,
    this.holdOutputUntilRelease = false,
    int? maxBytesPerWrite,
    int? queueHighWatermarkBytes,
    int? queueLowWatermarkBytes,
  }) : _maxBytesPerWrite = maxBytesPerWrite ?? _kDefaultMaxBytesPerWrite,
       _queueHighWatermarkBytes =
           queueHighWatermarkBytes ?? _kDefaultQueueHighWatermarkBytes,
       _queueLowWatermarkBytes =
           queueLowWatermarkBytes ?? _kDefaultQueueLowWatermarkBytes {
    if (_queueLowWatermarkBytes > _queueHighWatermarkBytes) {
      throw ArgumentError.value(
        _queueLowWatermarkBytes,
        'queueLowWatermarkBytes',
        'must be <= queueHighWatermarkBytes',
      );
    }
    _utf8Sink = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(StringConversionSink.fromStringSink(_textSink));
  }

  final Terminal _terminal;
  final List<int> Function(List<int>)? transform;
  final LogSink? logSink;
  final void Function(int bytes)? onBytesConsumed;
  final void Function(int bytes)? onBytesAccepted;
  bool holdOutputUntilRelease;

  OutputPipeMetrics get metrics => OutputPipeMetrics(
    queuedBytes: _buf.length,
    streamsPaused: _streamsPaused,
    pendingAcceptedBytes: _pendingAcceptedBytes,
    holdOutputUntilRelease: holdOutputUntilRelease,
  );

  final _buf = BytesBuilder(copy: false);
  Timer? _timer;
  final _subs = <StreamSubscription<List<int>>>[];
  var _streamsPaused = false;
  final int _maxBytesPerWrite;
  final int _queueHighWatermarkBytes;
  final int _queueLowWatermarkBytes;
  final _textSink = _TakeableStringSink();
  late final ByteConversionSink _utf8Sink;
  var _pendingAcceptedBytes = 0;

  static const _kDefaultMaxBytesPerWrite = 65536; // 64 KB
  static const _kFlushInterval = Duration(milliseconds: 16); // ~60 fps
  static const _kDefaultQueueHighWatermarkBytes = 512 * 1024;
  static const _kDefaultQueueLowWatermarkBytes = 128 * 1024;

  void bind(Stream<List<int>> stream) {
    _subs.add(stream.listen(_onChunk));
  }

  void _onChunk(List<int> chunk) {
    _buf.add(chunk);
    _pendingAcceptedBytes += chunk.length;
    _applyBackpressure();
    _acceptPendingBytesIfReady();
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (holdOutputUntilRelease) return;
    _timer ??= Timer(_kFlushInterval, _flush);
  }

  void releaseHeldOutput() {
    if (!holdOutputUntilRelease) return;
    holdOutputUntilRelease = false;
    _applyBackpressure();
    _acceptPendingBytesIfReady();
    if (_buf.isNotEmpty) {
      _scheduleFlush();
    }
  }

  void holdOutput() {
    holdOutputUntilRelease = true;
    _timer?.cancel();
    _timer = null;
  }

  void flushSync() {
    if (holdOutputUntilRelease) return;
    _timer?.cancel();
    _timer = null;
    while (_buf.isNotEmpty) {
      _flush();
    }
  }

  void _flush() {
    _timer = null;
    if (holdOutputUntilRelease) return;
    final all = _buf.takeBytes();
    if (all.isEmpty) return;

    final Uint8List toWrite;
    if (all.length > _maxBytesPerWrite) {
      toWrite = Uint8List.sublistView(all, 0, _maxBytesPerWrite);
      _buf.add(Uint8List.sublistView(all, _maxBytesPerWrite));
      _scheduleFlush();
    } else {
      toWrite = all;
    }

    logSink?.write(toWrite);

    List<int> out = toWrite;
    if (transform != null) {
      out = Uint8List.fromList(transform!(toWrite));
    }
    if (out.isNotEmpty) {
      _utf8Sink.add(out);
      final text = _textSink.take();
      if (text.isNotEmpty) {
        _terminal.write(text);
      }
    }
    onBytesConsumed?.call(toWrite.length);
    _applyBackpressure();
  }

  void _applyBackpressure() {
    if (_streamsPaused) {
      if (!holdOutputUntilRelease && _buf.length <= _queueLowWatermarkBytes) {
        for (final sub in _subs) {
          sub.resume();
        }
        _streamsPaused = false;
        _acceptPendingBytesIfReady();
      }
      return;
    }

    if (_buf.length > _queueHighWatermarkBytes) {
      for (final sub in _subs) {
        sub.pause();
      }
      _streamsPaused = true;
    }
  }

  void _acceptPendingBytesIfReady() {
    if (holdOutputUntilRelease ||
        _streamsPaused ||
        _pendingAcceptedBytes == 0) {
      return;
    }
    final bytes = _pendingAcceptedBytes;
    _pendingAcceptedBytes = 0;
    onBytesAccepted?.call(bytes);
  }

  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _utf8Sink.close();
    logSink?.close();
  }
}

class _TakeableStringSink implements StringSink {
  final _buffer = StringBuffer();

  String take() {
    final text = _buffer.toString();
    _buffer.clear();
    return text;
  }

  @override
  void write(Object? obj) => _buffer.write(obj);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? obj = '']) => _buffer.writeln(obj);
}
