import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// OS-keychain-backed credential store. Each SSH profile password is stored
/// under a per-profile key so the plaintext never touches disk.
class CredentialStorage {
  static final _storage = FlutterSecureStorage();
  static const _prefix = 'ssterm.pw.';

  static Future<void> store(String profileKey, String password) =>
      _storage.write(key: '$_prefix$profileKey', value: password);

  static Future<String?> load(String profileKey) =>
      _storage.read(key: '$_prefix$profileKey');

  static Future<void> delete(String profileKey) =>
      _storage.delete(key: '$_prefix$profileKey');
}
