import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xterm/xterm.dart';

import '../services/shell_integration.dart';

/// Minimal interface for session logging.
/// [SessionLogger] implements this structurally; cast as needed.
abstract interface class LogSink {
  void write(List<int> bytes);
  Future<void> close();
}

/// One completed command, captured via OSC 133 shell integration.
class CommandResult {
  /// Decoded, ANSI-stripped output captured between OSC 133 ; C and the
  /// matching OSC 133 ; D marker.  Always non-null but may be empty.
  final String output;

  /// Exit code from the OSC 133 ; D marker.  null if the shell did not
  /// include one (some pre-OSC133-spec implementations).
  final int? exitCode;

  /// True iff [output] was clipped at the [OutputPipe] capture cap (the
  /// command produced more bytes than we kept).  When set, downstream
  /// consumers (the agent's command-feedback formatter) MUST tell the LLM
  /// — otherwise it will reason about a silently incomplete tail.
  final bool truncated;

  CommandResult({
    required this.output,
    required this.exitCode,
    this.truncated = false,
  });
}

/// Bridges one or more `Stream<List<int>>` sources to a [Terminal].
///
/// Chunks are buffered for [_kFlushInterval] before each write so the main
/// thread is not blocked on rapid small writes (e.g. shell startup bursts).
/// Writes larger than [_kMaxBytesPerWrite] are split across multiple ticks so
/// the UI stays responsive during large output floods.
///
/// Also scans the output for OSC 133 ; C / ; D sequences (shell-integration
/// markers) and exposes:
///   - [commandFinished] — exit code on every D marker (legacy convenience).
///   - [commandResults]  — full [CommandResult] events on every C→D cycle.
///   - [awaitNextCommand] — convenience future used by the agent loop.
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

  /// Fires with the exit code whenever an OSC 133 ; D sequence is detected.
  final _commandFinishedCtrl = StreamController<int>.broadcast();
  Stream<int> get commandFinished => _commandFinishedCtrl.stream;

  /// Fires with the full [CommandResult] each time a C→D cycle completes.
  final _commandResultsCtrl = StreamController<CommandResult>.broadcast();
  Stream<CommandResult> get commandResults => _commandResultsCtrl.stream;

  /// True once at least one OSC 133 ; D sequence has been seen, meaning
  /// shell integration is active on this session.
  bool get hasOsc133 => _hasOsc133;
  var _hasOsc133 = false;

  // Output capture state — populated when we see OSC 133;C, drained on D.
  final _capturedOutput = BytesBuilder(copy: false);
  bool _capturing = false;

  // Number of `OSC 133;D` markers to silently drop before resuming normal
  // CommandResult emission.  Incremented when a caller abandons capture
  // (timeout / cancel) while the SHELL is still running the previous
  // command — when that command finally finishes, its D would otherwise
  // poison the NEXT awaitNextCommand with stale output.
  int _dropNextDs = 0;

  // Cap captured output so a runaway program (e.g. `yes`) can't OOM us.
  static const _kMaxCaptureBytes = 256 * 1024; // 256 KB

  // Keep the last 32 bytes of the previous flush so OSC sequences split
  // across flush boundaries are not missed.
  final _tailBytes = <int>[];
  static const _kOscTailKeep = 32;

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

    // Build a scan buffer that includes the tail of the previous flush so
    // OSC 133 sequences split across chunk boundaries are still found.
    final tailLen = _tailBytes.length;
    final scanBuf = Uint8List(tailLen + toWrite.length);
    if (tailLen > 0) {
      scanBuf.setRange(0, tailLen, _tailBytes);
      _tailBytes.clear();
    }
    scanBuf.setRange(tailLen, tailLen + toWrite.length, toWrite);

    final consumedInScanBuf = _processOsc133(scanBuf, tailLen);

    // Save tail for the NEXT cross-chunk scan, but ONLY bytes after the
    // last fully-processed marker.  Otherwise the same marker would be
    // re-discovered next flush and — worse — re-trigger its side effects
    // (re-emit a CommandResult, re-decrement _dropNextDs, etc.).
    final unconsumedStart =
        consumedInScanBuf > scanBuf.length ? scanBuf.length : consumedInScanBuf;
    final unconsumedLen = scanBuf.length - unconsumedStart;
    final keepLen = unconsumedLen > _kOscTailKeep ? _kOscTailKeep : unconsumedLen;
    if (keepLen > 0) {
      _tailBytes.addAll(
        Uint8List.sublistView(scanBuf, scanBuf.length - keepLen),
      );
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

  /// Walks every OSC 133 marker in [scanBuf] and slices the surrounding bytes
  /// (which originated *after* the [tailLen] prefix) into the captured-output
  /// buffer when we are inside a C→D window.
  ///
  /// Returns the position in [scanBuf] one past the last fully-processed
  /// marker (or [tailLen] if none were found, or [scanBuf.length] if
  /// trailing bytes were appended to capture).  Callers use this to decide
  /// which bytes are safe to feed into the next cross-chunk scan.
  int _processOsc133(Uint8List scanBuf, int tailLen) {
    final matches = findOsc133All(scanBuf);
    if (matches.isEmpty) {
      // No markers — if we are mid-capture, append the body bytes (sans the
      // re-fed tail, which was already counted last flush).
      if (_capturing) {
        _appendCapture(scanBuf, tailLen, scanBuf.length);
        return scanBuf.length;
      }
      return tailLen;
    }

    var cursor = tailLen; // start of "new" bytes inside scanBuf
    for (final m in matches) {
      // Bytes between the previous cursor and this marker belong to either
      // the active capture window (if _capturing) or get discarded.
      if (_capturing) {
        final hi = m.start < cursor ? cursor : m.start;
        _appendCapture(scanBuf, cursor, hi);
      }

      if (m.kind == 'C') {
        _capturing = true;
        _capturedOutput.clear();
      } else if (m.kind == 'D') {
        _hasOsc133 = true;
        if (!_commandFinishedCtrl.isClosed) {
          _commandFinishedCtrl.add(m.exitCode ?? 0);
        }
        // Was this D the late tail of an abandoned capture?  Drop it AND
        // clear any bytes we accumulated while waiting — they belong to a
        // command nobody is listening for anymore.  Crucially this happens
        // BEFORE we emit a CommandResult so the next awaiter only sees
        // markers from commands they actually issued.
        if (_dropNextDs > 0) {
          _dropNextDs--;
          _capturedOutput.takeBytes(); // discard
          _capturing = false;
          cursor = m.end;
          continue;
        }
        if (_capturing) {
          final wasCapped = _capturedOutput.length >= _kMaxCaptureBytes;
          final raw = utf8.decode(_capturedOutput.takeBytes(), allowMalformed: true);
          final clean = stripAnsi(raw).trim();
          _capturing = false;
          if (!_commandResultsCtrl.isClosed) {
            _commandResultsCtrl.add(
              CommandResult(
                output: clean,
                exitCode: m.exitCode,
                truncated: wasCapped,
              ),
            );
          }
        } else {
          // D without a preceding C.  Common sources:
          //   * shell startup: zsh/bash run `precmd` once before the first
          //     prompt, which fires our OSC 133;D hook with exit=0.
          //   * `zle reset-prompt`, terminal resize, or other re-renders that
          //     re-invoke `precmd_functions` without a real command in between.
          // Emitting a CommandResult here would hand a phantom empty result
          // to the next agent awaiter and misalign every subsequent capture
          // (each command gets the *previous* command's D).  Awaiters have
          // their own timeout, so we silently ignore these.  `_hasOsc133`
          // (set above) is enough to remember the shell installed the hook.
        }
      }

      cursor = m.end;
    }

    // Trailing bytes after the last marker.
    if (_capturing && cursor < scanBuf.length) {
      _appendCapture(scanBuf, cursor, scanBuf.length);
      return scanBuf.length;
    }
    return cursor;
  }

  void _appendCapture(Uint8List buf, int start, int end) {
    if (start >= end) return;
    final remaining = _kMaxCaptureBytes - _capturedOutput.length;
    if (remaining <= 0) return;
    final take = (end - start) > remaining ? remaining : (end - start);
    _capturedOutput.add(Uint8List.sublistView(buf, start, start + take));
  }

  /// Forget any in-progress capture and arrange to drop the NEXT pending
  /// `OSC 133;D` marker (if a shell command is still running in the
  /// background).  Call this when a previously-issued command was abandoned
  /// (timeout / cancel) so the eventual late D doesn't poison the next
  /// [awaitNextCommand].
  ///
  /// [drainNextD] should be `true` whenever the shell is presumed to still
  /// be running the abandoned command (it WILL emit a D eventually).  Set
  /// it to `false` only if you're confident the command has already
  /// finished (rare).
  void resetCapture({bool drainNextD = true}) {
    if (_capturing && drainNextD) {
      _dropNextDs++;
    }
    _capturing = false;
    _capturedOutput.takeBytes(); // discard
  }

  /// Awaits the next [CommandResult] (next OSC 133 ; D after this call).
  ///
  /// [timeout] caps how long we wait — returns null on timeout.  Call this
  /// AFTER sending a command's bytes to the shell.
  ///
  /// On timeout or cancel we automatically [resetCapture] so a late D from
  /// the abandoned command can't bleed into the NEXT awaiter.
  Future<CommandResult?> awaitNextCommand({
    Duration timeout = const Duration(seconds: 120),
    bool Function()? isCancelled,
  }) async {
    final completer = Completer<CommandResult?>();
    late StreamSubscription<CommandResult> sub;
    Timer? timer;
    Timer? cancelPoller;

    void finish(CommandResult? value, {required bool abandoned}) {
      if (completer.isCompleted) return;
      sub.cancel();
      timer?.cancel();
      cancelPoller?.cancel();
      if (abandoned) resetCapture();
      completer.complete(value);
    }

    sub = commandResults.listen((r) => finish(r, abandoned: false));
    timer = Timer(timeout, () => finish(null, abandoned: true));
    if (isCancelled != null) {
      cancelPoller = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (isCancelled()) finish(null, abandoned: true);
      });
    }

    return completer.future;
  }

  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _commandFinishedCtrl.close();
    _commandResultsCtrl.close();
    logSink?.close();
  }
}
