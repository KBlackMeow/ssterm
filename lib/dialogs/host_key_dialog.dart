import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/known_hosts_store.dart';
import '../utils/ssh_fingerprint.dart';

Future<bool> showHostKeyConfirmDialog(
  BuildContext context, {
  required String hostname,
  required int port,
  required String keyType,
  required String fingerprint,
}) {
  final host = port == 22 ? hostname : '$hostname:$port';
  final displayFp = formatMd5FingerprintFromStored(fingerprint);

  return showDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '验证主机密钥',
                style: TextStyle(
                  color: Color(0xFFD4D4D4),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '无法验证 $host 的真实性。\n'
                '这是首次连接该主机（未在 ~/.ssh/known_hosts 或 '
                '~/.ssterm/known_hosts.json 中找到）。请确认指纹后继续。',
                style: const TextStyle(
                  color: Color(0xFF8E8E8E),
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              _FingerprintBlock(keyType: keyType, fingerprint: displayFp),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('取消',
                        style: TextStyle(color: Color(0xFF8E8E8E))),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2472C8),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('信任并连接'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '信任后将保存至 ~/.ssterm/known_hosts.json',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    ),
  ).then((v) => v ?? false);
}

Future<void> showHostKeyChangedDialog(
  BuildContext context, {
  required String hostname,
  required int port,
  required KnownHostEntry existing,
  required String keyType,
  required String fingerprint,
}) {
  final host = port == 22 ? hostname : '$hostname:$port';
  final oldFp = formatMd5FingerprintFromStored(existing.fingerprint);
  final newFp = formatMd5FingerprintFromStored(fingerprint);

  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '主机密钥已变更',
                style: TextStyle(
                  color: Color(0xFFFF6E67),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '警告：$host 的远程主机密钥已变更，可能存在中间人攻击。\n'
                '连接已中止。若你确认服务器已更换密钥，请从 '
                '~/.ssh/known_hosts 或 ~/.ssterm/known_hosts.json '
                '中删除该主机对应条目后重试。',
                style: const TextStyle(
                  color: Color(0xFF8E8E8E),
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              const Text('先前记录的指纹',
                  style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 11)),
              const SizedBox(height: 6),
              _FingerprintBlock(
                keyType: existing.keyType,
                fingerprint: oldFp,
              ),
              const SizedBox(height: 12),
              const Text('当前收到的指纹',
                  style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 11)),
              const SizedBox(height: 6),
              _FingerprintBlock(keyType: keyType, fingerprint: newFp),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3A3A3A),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String formatMd5FingerprintFromStored(String stored) {
  final norm = normalizeFingerprint(stored);
  if (norm.length % 2 != 0) return stored;
  final bytes = <int>[];
  for (var i = 0; i < norm.length; i += 2) {
    bytes.add(int.parse(norm.substring(i, i + 2), radix: 16));
  }
  return formatMd5Fingerprint(Uint8List.fromList(bytes));
}

class _FingerprintBlock extends StatelessWidget {
  const _FingerprintBlock({
    required this.keyType,
    required this.fingerprint,
  });

  final String keyType;
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: SelectableText(
        '$keyType\n$fingerprint',
        style: const TextStyle(
          color: Color(0xFFC7C7C7),
          fontSize: 12,
          fontFamily: 'Menlo',
          height: 1.5,
        ),
      ),
    );
  }
}
