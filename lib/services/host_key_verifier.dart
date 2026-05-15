import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../dialogs/host_key_dialog.dart';
import '../utils/ssh_fingerprint.dart';
import 'trusted_host_keys.dart';

typedef SshHostKeyVerifier = Future<bool> Function(
  String keyType,
  Uint8List fingerprint,
);

SshHostKeyVerifier createHostKeyVerifier(
  BuildContext context, {
  required String hostname,
  required int port,
}) {
  return (String keyType, Uint8List fingerprint) async {
    final fp = normalizeFingerprint(formatMd5Fingerprint(fingerprint));

    if (await TrustedHostKeys.isTrusted(hostname, port, keyType, fp)) {
      return true;
    }

    final conflict = await TrustedHostKeys.conflictingEntry(
      hostname,
      port,
      keyType,
      fp,
    );
    if (conflict != null) {
      if (!context.mounted) return false;
      await showHostKeyChangedDialog(
        context,
        hostname: hostname,
        port: port,
        existing: conflict,
        keyType: keyType,
        fingerprint: fp,
      );
      return false;
    }

    if (!context.mounted) return false;
    final accepted = await showHostKeyConfirmDialog(
      context,
      hostname: hostname,
      port: port,
      keyType: keyType,
      fingerprint: fp,
    );
    if (accepted) {
      await TrustedHostKeys.trust(hostname, port, keyType, fp);
    }
    return accepted;
  };
}
