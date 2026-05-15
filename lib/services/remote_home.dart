import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

/// Resolves the remote login directory for initial SFTP listing.
Future<String> fetchRemoteHome(SSHClient client) async {
  try {
    final session = await client.execute(r'printf %s "$HOME"');
    final out = await session.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5));
    await session.done.timeout(const Duration(seconds: 3));
    final home = out.trim();
    if (home.isNotEmpty) return home;
  } catch (_) {}
  return '/';
}
