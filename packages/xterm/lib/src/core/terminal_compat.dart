/// Terminal behaviour tweaks for full-screen apps (e.g. vim) vs strict DEC/VT.
class TerminalCompat {
  const TerminalCompat({
    this.altDecScRcPositionOnly = true,
    this.altStripUnderlineOnWrite = true,
    this.altScrollDebounceMs = 8,
    this.ambiguousCharsAreWide = true,
  });

  /// vim-friendly defaults: position-only DECSC/DECRC in the alt buffer, strip
  /// spurious underline on writes, coalesce scroll wheel into one PTY write.
  static const vim = TerminalCompat();

  /// Strict DEC/VT: full DECSC/DECRC, no underline stripping, immediate scroll.
  static const strict = TerminalCompat(
    altDecScRcPositionOnly: false,
    altStripUnderlineOnWrite: false,
    altScrollDebounceMs: 0,
    ambiguousCharsAreWide: false,
  );

  /// In the alt buffer, [Buffer.saveCursor]/[restoreCursor] only move the
  /// cursor; colours, SGR, and charset are not saved or restored.
  final bool altDecScRcPositionOnly;

  /// In the alt buffer, do not store underline in newly written cells when the
  /// terminal cursor still has underline set (vim often desyncs from SGR).
  final bool altStripUnderlineOnWrite;

  /// Milliseconds to coalesce alt-buffer wheel/drag scroll before one PTY write.
  /// Zero flushes immediately (strict / low-latency).
  final int altScrollDebounceMs;

  /// Treat Unicode East Asian Ambiguous-width characters as fullwidth.
  ///
  /// CJK fallback fonts commonly render symbols such as ℃, ①, and box-drawing
  /// characters as fullwidth. Enabling this keeps glyphs, cursor movement, and
  /// following cells aligned in CJK-oriented terminals.
  final bool ambiguousCharsAreWide;
}
