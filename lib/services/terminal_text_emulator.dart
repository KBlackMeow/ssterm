/// Minimal line-oriented terminal emulator that turns a raw process byte
/// stream (already decoded to text) into the plain text a terminal would
/// finally show.
///
/// Agent commands run without a PTY, but tools such as hashcat, curl, pip or
/// apt still emit terminal control bytes: `\r` to redraw a status line,
/// `ESC[2K` / `ESC[K` to erase it, `ESC[nA` to move up and repaint a block,
/// and SGR colors. Treating that stream as plain text produces garbage in the
/// UI and wastes LLM tokens, so it is interpreted here instead of stripped
/// with regular expressions.
///
/// Supported: printable text, `\n`, `\r`, `\b`, CSI cursor movement
/// (A B C D E F G H f), erase (K, J) and everything else is parsed and
/// discarded (SGR, modes, OSC, DCS/APC/PM/SOS, charset selection).
///
/// Not a full emulator: no scrolling region, alternate screen or wide-char
/// cell accounting. `ESC[2J`/`3J` start a new "frame" at the cursor row
/// rather than erasing earlier scrollback, so earlier output is never lost.
class TerminalTextEmulator {
  TerminalTextEmulator({this.maxRows});

  /// Optional cap on retained rows (oldest dropped). Null keeps everything.
  final int? maxRows;

  final List<List<int>> _rows = [<int>[]];
  int _row = 0;
  int _col = 0;
  int _frameTop = 0;

  _State _state = _State.ground;
  final StringBuffer _params = StringBuffer();

  static final _needsEmulation = RegExp(r'[\x1b\r\x08]');

  /// True when [text] contains nothing the emulator would change.
  static bool isPlain(String text) => !_needsEmulation.hasMatch(text);

  /// One-shot conversion; returns [text] untouched when it is plain.
  static String render(String text) {
    if (isPlain(text)) return text;
    final emulator = TerminalTextEmulator()..write(text);
    return emulator.text;
  }

  /// The rendered text. A trailing newline in the input yields a trailing
  /// empty row, matching the plain-text behaviour.
  String get text => _rows.map(String.fromCharCodes).join('\n');

  /// Rendered rows. The trailing row is the cursor row; it is omitted when
  /// empty so callers see only lines with content.
  List<String> get lines {
    final out = _rows.map(String.fromCharCodes).toList();
    if (out.isNotEmpty && out.last.isEmpty) out.removeLast();
    return out;
  }

  void write(String data) {
    for (final c in data.runes) {
      _feed(c);
    }
    _trim();
  }

  void _feed(int c) {
    switch (_state) {
      case _State.ground:
        _ground(c);
      case _State.escape:
        _escape(c);
      case _State.escapeIntermediate:
        // ESC ( B, ESC # 8 ...: one final byte, nothing to render.
        _state = _State.ground;
      case _State.csi:
        _csi(c);
      case _State.string:
        if (c == 0x07) {
          _state = _State.ground;
        } else if (c == 0x1b) {
          _state = _State.stringEscape;
        }
      case _State.stringEscape:
        // ESC \ terminates; anything else is dropped as part of the string.
        _state = c == 0x5c ? _State.ground : _State.string;
    }
  }

  void _ground(int c) {
    switch (c) {
      case 0x1b:
        _state = _State.escape;
      case 0x0a: // LF: output is not behind a tty, so treat as CRLF.
        _lineFeed();
        _col = 0;
      case 0x0d:
        _col = 0;
      case 0x08:
        if (_col > 0) _col--;
      case 0x09:
        _put(c);
      default:
        if (c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0)) return;
        _put(c);
    }
  }

  void _escape(int c) {
    switch (c) {
      case 0x5b: // [
        _params.clear();
        _state = _State.csi;
      case 0x5d: // ] OSC
      case 0x50: // P DCS
      case 0x5f: // _ APC
      case 0x5e: // ^ PM
      case 0x58: // X SOS
        _state = _State.string;
      case 0x1b:
        break; // ESC ESC: stay in escape
      default:
        _state = c >= 0x20 && c <= 0x2f
            ? _State.escapeIntermediate
            : _State.ground;
    }
  }

  void _csi(int c) {
    if (c >= 0x40 && c <= 0x7e) {
      _state = _State.ground;
      _execCsi(c, _params.toString());
      return;
    }
    if (c == 0x1b) {
      _state = _State.escape; // malformed: restart
      return;
    }
    if (c >= 0x20 && c <= 0x3f) {
      if (_params.length < 64) _params.writeCharCode(c);
    }
  }

  void _execCsi(int finalByte, String raw) {
    // Private-mode sequences (ESC[?25l ...) carry no text.
    if (raw.isNotEmpty && '<=>?'.contains(raw[0])) return;
    final p = raw
        .split(';')
        .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')))
        .toList();
    int arg(int i, int def) {
      final v = i < p.length ? p[i] : null;
      return (v == null || v == 0) ? def : v;
    }

    switch (String.fromCharCode(finalByte)) {
      case 'A':
        _moveRow(-arg(0, 1));
      case 'B':
        _moveRow(arg(0, 1));
      case 'E':
        _moveRow(arg(0, 1));
        _col = 0;
      case 'F':
        _moveRow(-arg(0, 1));
        _col = 0;
      case 'C':
        _col += arg(0, 1);
      case 'D':
        _col = (_col - arg(0, 1)).clamp(0, _col);
      case 'G':
        _col = arg(0, 1) - 1;
      case 'H':
      case 'f':
        _setRow(_frameTop + arg(0, 1) - 1);
        _col = arg(1, 1) - 1;
      case 'K':
        _eraseLine(p.isEmpty ? 0 : (p[0] ?? 0));
      case 'J':
        _eraseDisplay(p.isEmpty ? 0 : (p[0] ?? 0));
    }
  }

  void _eraseLine(int mode) {
    final line = _rows[_row];
    switch (mode) {
      case 0:
        if (_col < line.length) line.length = _col;
      case 1:
        final end = (_col + 1).clamp(0, line.length);
        for (var i = 0; i < end; i++) {
          line[i] = 0x20;
        }
      case 2:
        line.clear();
    }
  }

  void _eraseDisplay(int mode) {
    switch (mode) {
      case 0:
        _eraseLine(0);
        if (_rows.length > _row + 1) _rows.removeRange(_row + 1, _rows.length);
      case 2:
      case 3:
        // Start a new frame here instead of destroying earlier output.
        _frameTop = _row;
        _eraseLine(0);
        if (_rows.length > _row + 1) _rows.removeRange(_row + 1, _rows.length);
        _rows[_row].clear();
    }
  }

  void _lineFeed() => _setRow(_row + 1);

  void _moveRow(int delta) => _setRow(_row + delta);

  void _setRow(int target) {
    final row = target < 0 ? 0 : target;
    while (_rows.length <= row) {
      _rows.add(<int>[]);
    }
    _row = row;
  }

  void _put(int c) {
    final line = _rows[_row];
    while (line.length < _col) {
      line.add(0x20);
    }
    if (_col < line.length) {
      line[_col] = c;
    } else {
      line.add(c);
    }
    _col++;
  }

  void _trim() {
    final cap = maxRows;
    if (cap == null || _rows.length <= cap * 2) return;
    final drop = _rows.length - cap;
    _rows.removeRange(0, drop);
    _row = (_row - drop).clamp(0, _rows.length - 1);
    _frameTop = (_frameTop - drop).clamp(0, _rows.length - 1);
  }
}

enum _State { ground, escape, escapeIntermediate, csi, string, stringEscape }
