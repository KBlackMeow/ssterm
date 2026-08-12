import 'dart:convert';
import 'dart:typed_data';

/// Encodes [script] the way PowerShell's `-EncodedCommand` expects: UTF-16LE
/// bytes, base64 encoded. Used by the interactive PowerShell terminal wrapper.
String encodePowerShellCommand(String script) {
  final units = script.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[i * 2] = units[i] & 0xFF;
    bytes[i * 2 + 1] = (units[i] >> 8) & 0xFF;
  }
  return base64.encode(bytes);
}
