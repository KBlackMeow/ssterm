import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/known_hosts_store.dart';
import '../utils/ssh_fingerprint.dart';
import '../widgets/frosted_glass.dart';

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
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 420,
        child: PopupSurface(color: FrostedGlassStyle.dialogFill,          child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Verify Host Key',
                style: TextStyle(
                  color: Color(0xFFD4D4D4),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'The authenticity of $host cannot be verified.\n'
                'This host was not found in ~/.ssh/known_hosts or '
                '~/.ssterm/known_hosts.json. Confirm the fingerprint before connecting.',
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
                    child: const Text('Cancel',
                        style: TextStyle(color: Color(0xFF8E8E8E))),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2472C8),
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Trust and Connect'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Fingerprint will be saved to ~/.ssterm/known_hosts.json',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 10),
              ),
            ],
          ),
        ),
        ),   // PopupSurface
      ),     // SizedBox
    ),       // Dialog
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
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 420,
        child: PopupSurface(color: FrostedGlassStyle.dialogFill, child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Host Key Changed',
                style: TextStyle(
                  color: Color(0xFFFF6E67),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'WARNING: The remote host key for $host has changed. '
                'This may indicate a man-in-the-middle attack.\n'
                'Connection aborted. If you are sure the server key was replaced, '
                'remove the entry from ~/.ssh/known_hosts or ~/.ssterm/known_hosts.json and retry.',
                style: const TextStyle(
                  color: Color(0xFF8E8E8E),
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              const Text('Known fingerprint',
                  style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 11)),
              const SizedBox(height: 6),
              _FingerprintBlock(
                keyType: existing.keyType,
                fingerprint: oldFp,
              ),
              const SizedBox(height: 12),
              const Text('Received fingerprint',
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
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        )),    // PopupSurface + Padding
      ),       // SizedBox
    ),         // Dialog
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
          fontFamily: 'JetBrainsMono',
          height: 1.5,
        ),
      ),
    );
  }
}
