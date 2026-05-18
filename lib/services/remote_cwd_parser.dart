import 'dart:convert';

/// Parses OSC 7 (`file://host/path`) sequences emitted by the remote shell.
class RemoteCwdParser {
  String _carry = '';

  /// Strips OSC 7 from [chunk] and returns the cleaned bytes plus any new cwd.
  ({List<int> cleaned, String? cwd}) process(List<int> chunk) {
    final input = _carry + utf8.decode(chunk, allowMalformed: true);
    _carry = '';

    String? cwd;
    final out = StringBuffer();
    var i = 0;

    while (i < input.length) {
      final start = input.indexOf('\x1b]7;', i);
      if (start == -1) {
        final tail = input.substring(i);
        _carry = _partialOscPrefix(tail);
        out.write(tail.substring(0, tail.length - _carry.length));
        break;
      }

      out.write(input.substring(i, start));
      final endBell = input.indexOf('\x07', start);
      final endSt = input.indexOf('\x1b\\', start);

      int end;
      if (endBell != -1 && (endSt == -1 || endBell < endSt)) {
        end = endBell + 1;
      } else if (endSt != -1) {
        end = endSt + 2;
      } else {
        _carry = input.substring(start);
        break;
      }

      cwd = _pathFromOsc(input.substring(start, end)) ?? cwd;
      i = end;
    }

    return (cleaned: utf8.encode(out.toString()), cwd: cwd);
  }

  static String _partialOscPrefix(String tail) {
    const markers = ['\x1b', '\x1b]', '\x1b]7', '\x1b]7;'];
    for (var n = markers.length; n > 0; n--) {
      final m = markers[n - 1];
      if (tail.endsWith(m)) return m;
    }
    return '';
  }

  static String? _pathFromOsc(String osc) {
    final m = RegExp(
      r'file://[^/\x07\x1b\\]*(/[^\x07\x1b\\]*)',
    ).firstMatch(osc);
    if (m == null) return null;
    final raw = m.group(1)!;
    if (raw.isEmpty) return '/';
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }
}
