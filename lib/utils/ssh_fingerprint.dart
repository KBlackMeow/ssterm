import 'dart:typed_data';

/// MD5 host key fingerprint in OpenSSH colon-separated form (e.g. `AA:BB:…`).
String formatMd5Fingerprint(Uint8List fingerprint) {
  return fingerprint
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// 去除指纹中的分隔符和大小写差异，生成统一表示。调用前应确保输入确实是指纹，
/// 而不是任意用户文本。
String normalizeFingerprint(String fingerprint) =>
    fingerprint.replaceAll(':', '').toLowerCase();

/// 按统一格式比较两个指纹，避免冒号、大小写等展示差异导致已知主机匹配失败。
bool fingerprintsEqual(String a, String b) =>
    normalizeFingerprint(a) == normalizeFingerprint(b);
