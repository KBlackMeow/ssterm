/// 将 SSH 主机密钥与本地信任记录核对；首次连接或密钥变化时通过对话框取得用户决
/// 定。密钥变化不会静默覆盖旧记录。

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../dialogs/host_key_dialog.dart';
import '../utils/ssh_fingerprint.dart';
import 'trusted_host_keys.dart';

/// `dartssh2` 握手期间调用的主机密钥验证函数，输入密钥类型和指纹，
/// 并异步返回是否继续连接。
typedef SshHostKeyVerifier =
    Future<bool> Function(String keyType, Uint8List fingerprint);

/// 创建连接专用的异步校验回调。匹配已信任记录时直接允许；
/// 首次密钥或指纹变化时要求用户确认，并在确认后更新受信任记录。
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
      final updated = await showHostKeyChangedDialog(
        context,
        hostname: hostname,
        port: port,
        existing: conflict,
        keyType: keyType,
        fingerprint: fp,
      );
      if (updated) {
        await TrustedHostKeys.trust(hostname, port, keyType, fp);
      }
      return updated;
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
