import 'dart:typed_data';

/// MD5 host key fingerprint in OpenSSH colon-separated form (e.g. `AA:BB:…`).
String formatMd5Fingerprint(Uint8List fingerprint) {
  return fingerprint
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

String normalizeFingerprint(String fingerprint) =>
    fingerprint.replaceAll(':', '').toLowerCase();

bool fingerprintsEqual(String a, String b) =>
    normalizeFingerprint(a) == normalizeFingerprint(b);
