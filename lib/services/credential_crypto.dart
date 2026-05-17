import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-256-GCM password obfuscation with a hardcoded key.
/// Protects against casual plaintext inspection; not a secret key system.
class CredentialCrypto {
  // 32-byte hardcoded key: "ssterm-password-encryption-keyv1"
  static final _key = Uint8List.fromList([
    0x73, 0x73, 0x74, 0x65, 0x72, 0x6d, 0x2d, 0x70,
    0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64, 0x2d,
    0x65, 0x6e, 0x63, 0x72, 0x79, 0x70, 0x74, 0x69,
    0x6f, 0x6e, 0x2d, 0x6b, 0x65, 0x79, 0x76, 0x31,
  ]);

  static Future<String> encrypt(String plaintext) async {
    final iv = _randomBytes(12);
    final plain = Uint8List.fromList(utf8.encode(plaintext));

    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(_key), 128, iv, Uint8List(0)));

    final out = Uint8List(plain.length + 16);
    final len = cipher.processBytes(plain, 0, plain.length, out, 0);
    cipher.doFinal(out, len);

    return '${base64Encode(iv)}:${base64Encode(out)}';
  }

  static Future<String?> decrypt(String payload) async {
    final sep = payload.indexOf(':');
    if (sep <= 0) return null;
    try {
      final iv = Uint8List.fromList(base64Decode(payload.substring(0, sep)));
      final cipherText =
          Uint8List.fromList(base64Decode(payload.substring(sep + 1)));

      final cipher = GCMBlockCipher(AESEngine())
        ..init(false, AEADParameters(KeyParameter(_key), 128, iv, Uint8List(0)));

      final out = Uint8List(cipherText.length);
      var offset = cipher.processBytes(cipherText, 0, cipherText.length, out, 0);
      offset += cipher.doFinal(out, offset);
      return utf8.decode(out.sublist(0, offset));
    } catch (_) {
      return null;
    }
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }
}
