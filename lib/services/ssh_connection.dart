import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/connect_result.dart';
import '../models/ssh_host.dart';
import 'host_key_verifier.dart';
import 'no_delay_socket.dart';

Future<ConnectResult> connectSshHost(
  SshHost host, {
  ConnectMode mode = ConnectMode.terminal,
  required SshHostKeyVerifier verifyHostKey,
}) async {
  final user = host.user?.trim() ?? '';
  if (user.isEmpty) {
    throw const FormatException('用户名不能为空');
  }

  List<SSHKeyPair>? identities;
  String? Function()? onPassword;

  if (host.password != null && host.password!.isNotEmpty) {
    onPassword = () => host.password!;
  } else if (host.identityFile != null && host.identityFile!.isNotEmpty) {
    final path = expandHomePath(host.identityFile!);
    final f = File(path);
    if (!await f.exists()) {
      throw FormatException('密钥文件不存在:\n$path');
    }
    identities = SSHKeyPair.fromPem(await f.readAsString());
    if (identities.isEmpty) {
      throw FormatException('无法解析密钥:\n$path');
    }
  } else {
    final home = Platform.environment['HOME'] ?? '';
    for (final p in [
      '$home/.ssh/id_ed25519',
      '$home/.ssh/id_rsa',
      '$home/.ssh/id_ecdsa',
    ]) {
      final f = File(p);
      if (await f.exists()) {
        try {
          identities = SSHKeyPair.fromPem(await f.readAsString());
          if (identities.isNotEmpty) break;
        } catch (_) {
          identities = null;
        }
      }
    }
  }

  final socket = await NoDelaySocket.connect(
    host.hostname,
    host.port,
    timeout: const Duration(seconds: 10),
  );

  final client = SSHClient(
    socket,
    username: user,
    identities: identities,
    onPasswordRequest: onPassword,
    onVerifyHostKey: (type, fingerprint) =>
        verifyHostKey(type, fingerprint),
  );

  try {
    SSHSession? session;
    SftpClient? sftp;

    if (mode == ConnectMode.terminal) {
      session = await client
          .shell(
            pty: const SSHPtyConfig(
              width: 80,
              height: 24,
              type: 'xterm-256color',
            ),
          )
          .timeout(const Duration(seconds: 15));
    } else {
      sftp = await client.sftp().timeout(const Duration(seconds: 15));
    }

    return ConnectResult(
      client: client,
      session: session,
      sftp: sftp,
      host: host.hostname,
      username: user,
      alias: host.alias,
      profile: host,
      mode: mode,
    );
  } catch (e) {
    client.close();
    rethrow;
  }
}

/// Connect from dialog fields (IP, port, username, password or key path).
Future<ConnectResult> connectSshParams({
  required String hostname,
  required int port,
  required String username,
  String? alias,
  String? password,
  String? identityFile,
  required SshHostKeyVerifier verifyHostKey,
}) async {
  final host = hostname.trim();
  final user = username.trim();

  if (host.isEmpty) {
    throw const FormatException('请输入 IP 或主机名');
  }
  if (user.isEmpty) {
    throw const FormatException('用户名不能为空');
  }

  final pwd = password?.trim();
  final keyPath = identityFile?.trim();
  final resolvedPassword = (pwd != null && pwd.isNotEmpty) ? pwd : null;
  final resolvedKey = (keyPath != null && keyPath.isNotEmpty)
      ? expandHomePath(keyPath)
      : null;

  final name = alias?.trim();
  final resolvedAlias = (name != null && name.isNotEmpty)
      ? name
      : (port == 22 ? host : '$host:$port');
  final sshHost = SshHost(
    alias: resolvedAlias,
    hostname: host,
    port: port,
    user: user,
    identityFile: resolvedKey,
    password: resolvedPassword,
  );

  final result = await connectSshHost(
    sshHost,
    verifyHostKey: verifyHostKey,
  );
  return result;
}
