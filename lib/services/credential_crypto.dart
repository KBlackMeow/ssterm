import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// Encrypts credentials at rest; master key lives in the OS keychain.
class CredentialCrypto {
  static const _masterKeyId = 'ssterm_credential_master_key_v1';
  static const _storage = FlutterSecureStorage();

  static Future<Uint8List> _masterKeyBytes() async {
    var stored = await _storage.read(key: _masterKeyId);
    if (stored == null) {
      final key = _randomBytes(32);
      await _storage.write(key: _masterKeyId, value: base64Encode(key));
      return key;
    }
    return Uint8List.fromList(base64Decode(stored));
  }

  static Future<String> encrypt(String plaintext) async {
    final key = await _masterKeyBytes();
    final iv = _randomBytes(12);
    final plain = Uint8List.fromList(utf8.encode(plaintext));

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          128,
          iv,
          Uint8List(0),
        ),
      );

    final out = Uint8List(plain.length + 16);
    final len = cipher.processBytes(plain, 0, plain.length, out, 0);
    cipher.doFinal(out, len);

    return '${base64Encode(iv)}:${base64Encode(out)}';
  }

  static Future<String?> decrypt(String payload) async {
    final sep = payload.indexOf(':');
    if (sep <= 0) return null;
    try {
      final key = await _masterKeyBytes();
      final iv = Uint8List.fromList(base64Decode(payload.substring(0, sep)));
      final cipherText =
          Uint8List.fromList(base64Decode(payload.substring(sep + 1)));

      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            128,
            iv,
            Uint8List(0),
          ),
        );

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
