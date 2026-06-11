import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/ssh_host.dart';
import '../utils/app_dir.dart';
import 'no_delay_socket.dart';

/// Arguments passed to the download isolate via [Isolate.spawn].
/// All fields must be isolate-sendable (no native resources).
class SftpDownloadArgs {
  const SftpDownloadArgs({
    required this.host,
    required this.remotePath,
    required this.localPath,
    required this.replyPort,
  });

  final SshHost host;
  final String remotePath;
  final String localPath;
  final SendPort replyPort;
}

/// Wire protocol on [SftpDownloadArgs.replyPort]:
///   [int] bytes ≥ 0  → progress: bytes received so far
///   [null]            → transfer complete
///   [String]          → error message
///
/// Top-level function required by [Isolate.spawn].
Future<void> sftpDownloadMain(SftpDownloadArgs args) async {
  SSHClient? client;
  IOSink? sink;
  try {
    final h = args.host;
    final user = h.user?.trim() ?? SshHost.defaultUsername;

    List<SSHKeyPair>? identities;
    String? Function()? onPassword;

    if (h.usesPassword) {
      onPassword = () => h.password!;
    } else if (h.usesIdentityFile) {
      final path = expandHomePath(h.identityFile!);
      identities = SSHKeyPair.fromPem(await File(path).readAsString());
    } else {
      identities = await _loadDefaultIdentities();
    }

    final socket = await NoDelaySocket.connect(
      h.hostname,
      h.port,
      timeout: const Duration(seconds: 15),
    );
    client = SSHClient(
      socket,
      username: user,
      identities: identities,
      onPasswordRequest: onPassword,
      // The user already accepted this host key when the main tab connected.
      onVerifyHostKey: (_, _) => true,
    );
    await client.authenticated.timeout(const Duration(seconds: 15));

    final sftp = await client.sftp().timeout(const Duration(seconds: 15));
    final remoteFile = await sftp.open(
      args.remotePath,
      mode: SftpFileOpenMode.read,
    );
    sink = File(args.localPath).openWrite();

    int received = 0;
    await for (final chunk in remoteFile.read().cast<Uint8List>()) {
      sink.add(chunk);
      received += chunk.length;
      args.replyPort.send(received);
    }

    await sink.flush();
    await sink.close();
    sink = null;
    await remoteFile.close();
    sftp.close();

    args.replyPort.send(null); // done
  } catch (e) {
    await sink?.close();
    args.replyPort.send('$e'); // error
  } finally {
    client?.close();
  }
}

Future<List<SSHKeyPair>?> _loadDefaultIdentities() async {
  final ssh = userSshDir();
  for (final path in [
    '$ssh/id_ed25519',
    '$ssh/id_rsa',
    '$ssh/id_ecdsa',
  ]) {
    try {
      final f = File(path);
      if (await f.exists()) {
        final kp = SSHKeyPair.fromPem(await f.readAsString());
        if (kp.isNotEmpty) return kp;
      }
    } catch (_) {}
  }
  return null;
}
