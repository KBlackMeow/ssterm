import 'dart:async';
import 'dart:collection';
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

/// Byte-oriented terminal backend used when parsing is owned outside Dart.
abstract interface class TerminalByteSink {
  void write(List<int> bytes);
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

  /// Final working directory verified by the executor's private completion
  /// envelope. Null when execution failed, was cancelled, or no envelope was
  /// observed.
  final String? effectiveCwd;

  CommandResult({
    required this.output,
    required this.exitCode,
    this.truncated = false,
    this.cancelled = false,
    this.effectiveCwd,
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
    this.terminalByteSink,
    this.holdOutputUntilRelease = false,
    this.pauseSourceOnBackpressure = true,
    int? maxBytesPerWrite,
    int? queueHighWatermarkBytes,
    int? queueLowWatermarkBytes,
  }) : _maxBytesPerWrite =
           maxBytesPerWrite ??
           (terminalByteSink == null
               ? _kDefaultMaxBytesPerWrite
               : _kNativeMaxBytesPerWrite),
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
  final TerminalByteSink? terminalByteSink;
  bool holdOutputUntilRelease;

  /// Whether the bound source subscriptions may be paused at the queue high
  /// watermark. Keep this disabled for SSH channel streams: pausing them can
  /// stop channel-window updates and leave a remote writer blocked forever.
  final bool pauseSourceOnBackpressure;

  OutputPipeMetrics get metrics => OutputPipeMetrics(
    queuedBytes: _queuedBytes,
    streamsPaused: _streamsPaused,
    pendingAcceptedBytes: _pendingAcceptedBytes,
    holdOutputUntilRelease: holdOutputUntilRelease,
  );

  // Keep source chunks segmented.  A BytesBuilder requires takeBytes() to
  // materialize the entire backlog; taking 64 KB from a multi-megabyte flood
  // and then putting the remainder back therefore recopies the shrinking
  // backlog on every frame (quadratic total work).  A deque lets each flush
  // consume only the bytes it is actually going to parse.
  final _chunks = ListQueue<Uint8List>();
  var _queuedBytes = 0;
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
  // Native parsing mutates a complete batch before publishing one screen
  // snapshot, so it can safely amortize a much larger output burst per frame.
  // Two MiB keeps ordinary ANSI-heavy parsing close to one frame while
  // allowing plain line floods to amortize FFI and snapshot publication.
  static const _kNativeMaxBytesPerWrite = 2 * 1024 * 1024;
  static const _kFlushInterval = Duration(milliseconds: 16); // ~60 fps
  static const _kDefaultQueueHighWatermarkBytes = 512 * 1024;
  static const _kDefaultQueueLowWatermarkBytes = 128 * 1024;

  void bind(Stream<List<int>> stream) {
    _subs.add(stream.listen(_onChunk));
  }

  void _onChunk(List<int> chunk) {
    if (chunk.isEmpty) return;
    _chunks.addLast(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    _queuedBytes += chunk.length;
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
    if (_queuedBytes != 0) {
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
    while (_queuedBytes != 0) {
      _flush();
    }
  }

  void _flush() {
    _timer = null;
    if (holdOutputUntilRelease) return;
    if (_queuedBytes == 0) return;

    final toWrite = _takeQueuedBytes(_maxBytesPerWrite);
    if (_queuedBytes != 0) {
      _scheduleFlush();
    }

    logSink?.write(toWrite);

    if (terminalByteSink != null) {
      // The transform may observe OSC metadata (for example cwd), but Rust
      // must receive the untouched byte stream. Avoid materializing the
      // transform's cleaned copy when Dart will not parse it.
      transform?.call(toWrite);
      terminalByteSink!.write(toWrite);
    } else {
      final out = transform == null
          ? toWrite
          : Uint8List.fromList(transform!(toWrite));
      if (out.isEmpty) {
        onBytesConsumed?.call(toWrite.length);
        _applyBackpressure();
        return;
      }
      _utf8Sink.add(out);
      final text = _textSink.take();
      if (text.isNotEmpty) {
        _terminal.write(text);
      }
    }
    onBytesConsumed?.call(toWrite.length);
    _applyBackpressure();
  }

  Uint8List _takeQueuedBytes(int maximum) {
    final count = _queuedBytes < maximum ? _queuedBytes : maximum;
    final first = _chunks.removeFirst();

    if (first.length >= count) {
      final result = first.length == count
          ? first
          : Uint8List.sublistView(first, 0, count);
      if (first.length > count) {
        _chunks.addFirst(Uint8List.sublistView(first, count));
      }
      _queuedBytes -= count;
      return result;
    }

    final result = Uint8List(count);
    var offset = 0;
    result.setRange(offset, offset + first.length, first);
    offset += first.length;

    while (offset < count) {
      final chunk = _chunks.removeFirst();
      final remaining = count - offset;
      final copied = chunk.length < remaining ? chunk.length : remaining;
      result.setRange(offset, offset + copied, chunk);
      offset += copied;
      if (copied < chunk.length) {
        _chunks.addFirst(Uint8List.sublistView(chunk, copied));
      }
    }

    _queuedBytes -= count;
    return result;
  }

  void _applyBackpressure() {
    if (!pauseSourceOnBackpressure) return;
    if (_streamsPaused) {
      if (!holdOutputUntilRelease && _queuedBytes <= _queueLowWatermarkBytes) {
        for (final sub in _subs) {
          sub.resume();
        }
        _streamsPaused = false;
        _acceptPendingBytesIfReady();
      }
      return;
    }

    if (_queuedBytes > _queueHighWatermarkBytes) {
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
