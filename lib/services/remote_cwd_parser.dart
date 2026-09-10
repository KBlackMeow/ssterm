import 'dart:convert';

/// Parses OSC 7 (`file://host/path`) sequences emitted by the remote shell.
class RemoteCwdParser {
  String _carry = '';
  final List<int> _metadataOsc = <int>[];
  var _metadataPrefixLength = 0;
  var _metadataInOsc7 = false;
  var _metadataSawEscape = false;

  static const _osc7Prefix = <int>[0x1b, 0x5d, 0x37, 0x3b];
  static const _maxMetadataOscBytes = 16 * 1024;

  /// Observes OSC 7 metadata without decoding or copying ordinary output.
  ///
  /// Rust-backed terminals parse the original bytes themselves, so calling
  /// [process] there would pointlessly turn every output flood into a Dart
  /// String and then encode it again. This byte state machine allocates only
  /// while an actual OSC 7 sequence is in flight.
  String? observe(List<int> chunk) {
    String? cwd;
    for (final byte in chunk) {
      if (_metadataInOsc7) {
        _metadataOsc.add(byte);
        final terminated = byte == 0x07 || (_metadataSawEscape && byte == 0x5c);
        _metadataSawEscape = byte == 0x1b;
        if (terminated) {
          final osc = utf8.decode(_metadataOsc, allowMalformed: true);
          cwd = _pathFromOsc(osc) ?? cwd;
          _resetMetadataOsc();
        } else if (_metadataOsc.length > _maxMetadataOscBytes) {
          _resetMetadataOsc();
        }
        continue;
      }

      if (byte == _osc7Prefix[_metadataPrefixLength]) {
        _metadataPrefixLength++;
        if (_metadataPrefixLength == _osc7Prefix.length) {
          _metadataInOsc7 = true;
          _metadataOsc
            ..clear()
            ..addAll(_osc7Prefix);
          _metadataPrefixLength = 0;
          _metadataSawEscape = false;
        }
      } else {
        // ESC can be both the failed candidate's final byte and the start of
        // the next candidate.
        _metadataPrefixLength = byte == _osc7Prefix.first ? 1 : 0;
      }
    }
    return cwd;
  }

  void _resetMetadataOsc() {
    _metadataOsc.clear();
    _metadataInOsc7 = false;
    _metadataSawEscape = false;
  }

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
    return decodeFileUriPath(m.group(1)!);
  }

  /// Converts the raw value retained by the native OSC 7 parser into the
  /// path used by the terminal tab and SFTP view.
  static String? pathFromFileUri(String value) {
    final match = RegExp(r'^file://[^/]*(/.*)$').firstMatch(value);
    if (match == null) return null;
    return decodeFileUriPath(match.group(1)!);
  }

  static String? decodeFileUriPath(String raw) {
    if (raw.isEmpty) return '/';
    try {
      final decoded = Uri.decodeComponent(raw);
      // Reject paths with traversal segments to prevent a malicious server
      // from redirecting the SFTP panel to unintended directories.
      if (decoded.split('/').contains('..')) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }
}
