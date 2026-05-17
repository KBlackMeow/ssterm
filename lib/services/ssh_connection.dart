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
  SshHostKeyVerifier? jumpVerifyHostKey,
}) async {
  final user = host.user?.trim() ?? '';
  if (user.isEmpty) {
    throw const FormatException('用户名不能为空');
  }

  SSHClient? jumpClient;

  // Feature 2: connect via jump host if configured
  if (host.jumpHost != null) {
    final jump = host.jumpHost!;
    final jumpUser = jump.user?.trim() ?? SshHost.defaultUsername;

    List<SSHKeyPair>? jumpIdentities;
    String? Function()? jumpOnPassword;

    if (jump.password != null && jump.password!.isNotEmpty) {
      jumpOnPassword = () => jump.password!;
    } else if (jump.identityFile != null && jump.identityFile!.isNotEmpty) {
      final path = expandHomePath(jump.identityFile!);
      final f = File(path);
      if (!await f.exists()) throw FormatException('跳板机密钥文件不存在:\n$path');
      jumpIdentities = SSHKeyPair.fromPem(await f.readAsString());
    } else {
      jumpIdentities = await _defaultIdentities();
    }

    final jumpSocket = await NoDelaySocket.connect(
      jump.hostname,
      jump.port,
      timeout: const Duration(seconds: 10),
    );

    jumpClient = SSHClient(
      jumpSocket,
      username: jumpUser,
      identities: jumpIdentities,
      onPasswordRequest: jumpOnPassword,
      onVerifyHostKey: jumpVerifyHostKey != null
          ? (type, fp) => jumpVerifyHostKey(type, fp)
          : (_, _) async => true,
    );

    await jumpClient.authenticated
        .timeout(const Duration(seconds: 15), onTimeout: () {
      jumpClient!.close();
      throw TimeoutException('跳板机认证超时');
    });
  }

  List<SSHKeyPair>? identities;
  String? Function()? onPassword;

  if (host.password != null && host.password!.isNotEmpty) {
    onPassword = () => host.password!;
  } else if (host.identityFile != null && host.identityFile!.isNotEmpty) {
    final path = expandHomePath(host.identityFile!);
    final f = File(path);
    if (!await f.exists()) {
      jumpClient?.close();
      throw FormatException('密钥文件不存在:\n$path');
    }
    identities = SSHKeyPair.fromPem(await f.readAsString());
    if (identities.isEmpty) {
      jumpClient?.close();
      throw FormatException('无法解析密钥:\n$path');
    }
  } else {
    identities = await _defaultIdentities();
  }

  // Use tunnel socket when jump host is present, otherwise direct TCP
  final socket = jumpClient != null
      ? await jumpClient
          .forwardLocal(host.hostname, host.port)
          .timeout(const Duration(seconds: 10), onTimeout: () {
          jumpClient!.close();
          throw TimeoutException('跳板机隧道建立超时');
        })
      : await NoDelaySocket.connect(
          host.hostname,
          host.port,
          timeout: const Duration(seconds: 10),
        );

  final client = SSHClient(
    socket,
    username: user,
    identities: identities,
    onPasswordRequest: onPassword,
    onVerifyHostKey: (type, fingerprint) => verifyHostKey(type, fingerprint),
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
      jumpClient: jumpClient,
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
    jumpClient?.close();
    rethrow;
  }
}

/// Connect from dialog fields.
Future<ConnectResult> connectSshParams({
  required String hostname,
  required int port,
  required String username,
  String? alias,
  String? password,
  String? identityFile,
  SshHost? jumpHost,
  List<dynamic> forwardRules = const [],
  int keepaliveInterval = 0,
  bool autoReconnect = false,
  bool sessionLog = false,
  required SshHostKeyVerifier verifyHostKey,
  SshHostKeyVerifier? jumpVerifyHostKey,
}) async {
  final host = hostname.trim();
  final user = username.trim();

  if (host.isEmpty) throw const FormatException('请输入 IP 或主机名');
  if (user.isEmpty) throw const FormatException('用户名不能为空');

  final pwd = password?.trim();
  final keyPath = identityFile?.trim();

  final name = alias?.trim();
  final resolvedAlias =
      (name != null && name.isNotEmpty) ? name : (port == 22 ? host : '$host:$port');

  final sshHost = SshHost(
    alias: resolvedAlias,
    hostname: host,
    port: port,
    user: user,
    identityFile: (keyPath != null && keyPath.isNotEmpty) ? expandHomePath(keyPath) : null,
    password: (pwd != null && pwd.isNotEmpty) ? pwd : null,
    jumpHost: jumpHost,
    keepaliveInterval: keepaliveInterval,
    autoReconnect: autoReconnect,
    sessionLog: sessionLog,
  );

  return connectSshHost(
    sshHost,
    verifyHostKey: verifyHostKey,
    jumpVerifyHostKey: jumpVerifyHostKey,
  );
}

Future<List<SSHKeyPair>?> _defaultIdentities() async {
  final home = Platform.environment['HOME'] ?? '';
  for (final p in [
    '$home/.ssh/id_ed25519',
    '$home/.ssh/id_rsa',
    '$home/.ssh/id_ecdsa',
  ]) {
    final f = File(p);
    if (await f.exists()) {
      try {
        final kp = SSHKeyPair.fromPem(await f.readAsString());
        if (kp.isNotEmpty) return kp;
      } catch (_) {}
    }
  }
  return null;
}
