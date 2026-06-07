/// Shell integration via OSC 133 — the same escape-sequence protocol used by
/// iTerm2, VS Code's integrated terminal, Warp, Zed, and many other terminal
/// emulators.
///
/// The shell hooks are installed via the wrapper in [ssh_connection.dart]
/// (and [local_shell_wrapper.dart] for local sessions); this library only
/// provides the byte-level OSC 133 parser used by [OutputPipe] to detect
/// command boundaries.
///
/// Sequences we care about:
///   - `ESC ] 133 ; C BEL/ST`            — command output begins
///   - `ESC ] 133 ; D ; <exitCode> BEL/ST` — command output ends with exit code
///
/// Together they let us extract the exact stdout/stderr bytes a command
/// produced, plus its exit code — the foundation for an industry-standard
/// agent loop.
library;

/// Outcome of a single OSC 133 scan.
class Osc133Match {
  /// Marker kind: 'C' (output start) or 'D' (output end).
  final String kind;

  /// Exit code parsed from a `D` marker.  null for `C` markers.
  final int? exitCode;

  /// Index in the scanned buffer where the marker BEGINS (the ESC byte).
  final int start;

  /// Index in the scanned buffer one past the marker's terminator (BEL or ST).
  final int end;

  const Osc133Match({
    required this.kind,
    required this.start,
    required this.end,
    this.exitCode,
  });
}

/// Tries to parse an OSC 133 sequence starting at [offset] in [bytes].
/// Returns the [Osc133Match] on success, or null if the bytes don't start
/// with a recognised OSC 133 ; C / OSC 133 ; D sequence.
Osc133Match? _tryParseAt(List<int> bytes, int offset) {
  // Need at least: ESC ] 1 3 3 ; X BEL = 8 bytes.
  if (bytes.length - offset < 8) return null;
  if (bytes[offset] != 0x1B || bytes[offset + 1] != 0x5D) return null;

  // Must match "133;"
  const prefix = [0x31, 0x33, 0x33, 0x3B]; // "133;"
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[offset + 2 + i] != prefix[i]) return null;
  }

  final kindByte = bytes[offset + 6];
  var pos = offset + 7;

  if (kindByte == 0x43) {
    // 'C' — output start.  Optional ;params... ignored.  Just find terminator.
    final term = _findTerminator(bytes, pos);
    if (term == null) return null;
    return Osc133Match(kind: 'C', start: offset, end: term);
  }

  if (kindByte == 0x44) {
    // 'D' — output end.  Optional `;<exit_code>`.
    if (pos < bytes.length && bytes[pos] == 0x3B) pos++;
    var code = 0;
    var hasDigits = false;
    while (pos < bytes.length && bytes[pos] >= 0x30 && bytes[pos] <= 0x39) {
      code = code * 10 + (bytes[pos] - 0x30);
      pos++;
      hasDigits = true;
    }
    final term = _findTerminator(bytes, pos);
    if (term == null) return null;
    return Osc133Match(
      kind: 'D',
      start: offset,
      end: term,
      exitCode: hasDigits ? code : null,
    );
  }

  return null;
}

/// Returns the index *after* the OSC terminator (BEL or ESC \) starting at
/// [pos] in [bytes], or null if the buffer is truncated before a terminator.
int? _findTerminator(List<int> bytes, int pos) {
  // Bound the search so a runaway scan can't blow up on a non-OSC-133 stream
  // that happens to start with "ESC ] 133 ; C".
  final limit = pos + 64 < bytes.length ? pos + 64 : bytes.length;
  for (var i = pos; i < limit; i++) {
    final b = bytes[i];
    if (b == 0x07) return i + 1;
    if (b == 0x1B && i + 1 < limit && bytes[i + 1] == 0x5C) return i + 2;
    // OSC sequences don't contain other control bytes; if we see one,
    // assume the sequence is malformed and stop.
    if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return null;
  }
  return null;
}

/// Scans [data] for OSC 133 ; C and OSC 133 ; D sequences and returns every
/// match in order.  Returns an empty list if none were found.
List<Osc133Match> findOsc133All(List<int> data) {
  final out = <Osc133Match>[];
  for (var i = 0; i + 1 < data.length; i++) {
    if (data[i] == 0x1B && data[i + 1] == 0x5D) {
      final m = _tryParseAt(data, i);
      if (m != null) {
        out.add(m);
        i = m.end - 1; // -1 because the for-loop will ++ it
      }
    }
  }
  return out;
}

/// Convenience: returns the exit code of the FIRST OSC 133 ; D sequence in
/// [data], or null if none is present.  Kept for backwards compatibility.
int? findOsc133D(List<int> data) {
  for (final m in findOsc133All(data)) {
    if (m.kind == 'D') return m.exitCode ?? 0;
  }
  return null;
}

/// Strip ANSI / VT100 escape sequences (CSI, OSC, simple ESC X) from [text].
/// Used to clean up captured command output before sending it to the LLM —
/// otherwise the model spends tokens decoding colour codes and cursor moves.
String stripAnsi(String text) {
  // Order matters: OSC first (can contain `;` which would confuse CSI), then
  // CSI (`ESC [ ... <final byte 0x40-0x7E>`), then simple two-byte escapes,
  // then bare control characters we don't want.
  final osc = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');
  final csi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  final simpleEsc = RegExp(r'\x1B[@-Z\\-_]');
  // SS2/SS3 + DCS/SOS/PM/APC: ESC [NOPX] ... ST
  final dcsLike = RegExp(r'\x1B[NOPX^_][^\x1B]*(?:\x1B\\)?');
  // Backspace, BEL, vertical tab, form feed.
  final stripCtrl = RegExp(r'[\x07\x08\x0B\x0C]');
  return text
      .replaceAll(osc, '')
      .replaceAll(csi, '')
      .replaceAll(dcsLike, '')
      .replaceAll(simpleEsc, '')
      .replaceAll(stripCtrl, '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
}
