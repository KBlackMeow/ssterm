import 'dart:convert';

/// Parses OSC 7 (`file://host/path`) sequences emitted by the remote shell.
class RemoteCwdParser {
  final List<int> _processPrefix = <int>[];
  final List<int> _processOsc = <int>[];
  var _processInOsc7 = false;
  var _processSawEscape = false;

  static const _osc7Prefix = <int>[0x1b, 0x5d, 0x37, 0x3b];
  static const _maxMetadataOscBytes = 16 * 1024;

  /// Strips OSC 7 from [chunk] and returns the cleaned bytes plus any new cwd.
  ({List<int> cleaned, String? cwd}) process(List<int> chunk) {
    final out = <int>[];
    String? cwd;
    for (final byte in chunk) {
      if (_processInOsc7) {
        _processOsc.add(byte);
        final terminated = byte == 0x07 || (_processSawEscape && byte == 0x5c);
        _processSawEscape = byte == 0x1b;
        if (terminated) {
          final osc = utf8.decode(_processOsc, allowMalformed: true);
          cwd = _pathFromOsc(osc) ?? cwd;
          _resetProcessOsc();
        } else if (_processOsc.length > _maxMetadataOscBytes) {
          // This was not credible cwd metadata. Preserve it byte-for-byte
          // instead of silently swallowing arbitrary terminal output.
          out.addAll(_processOsc);
          _resetProcessOsc();
        }
        continue;
      }

      _processOrdinaryByte(byte, out);
    }
    return (cleaned: out, cwd: cwd);
  }

  void _processOrdinaryByte(int byte, List<int> out) {
    if (_processPrefix.isEmpty) {
      if (byte == _osc7Prefix.first) {
        _processPrefix.add(byte);
      } else {
        out.add(byte);
      }
      return;
    }

    final expected = _osc7Prefix[_processPrefix.length];
    if (byte == expected) {
      _processPrefix.add(byte);
      if (_processPrefix.length == _osc7Prefix.length) {
        _processInOsc7 = true;
        _processOsc
          ..clear()
          ..addAll(_processPrefix);
        _processPrefix.clear();
        _processSawEscape = false;
      }
      return;
    }

    out.addAll(_processPrefix);
    _processPrefix.clear();
    // A mismatching ESC may itself begin the next OSC 7 prefix.
    if (byte == _osc7Prefix.first) {
      _processPrefix.add(byte);
    } else {
      out.add(byte);
    }
  }

  void _resetProcessOsc() {
    _processOsc.clear();
    _processInOsc7 = false;
    _processSawEscape = false;
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
