import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/connect_result.dart';
import '../models/ssh_host.dart';
import '../utils/app_dir.dart';
import 'host_key_verifier.dart';
import 'no_delay_socket.dart';
import 'ssh_shell_integration.dart';

export 'ssh_shell_integration.dart' show openSshLoginShell;

/// 使用主机档案完成跳板/直连、主机密钥校验、认证和会话初始化。
/// 成功时返回 `ConnectResult`；任一步骤失败都会先清理已建立的
/// SSH 或跳板资源，再向上传递错误。
Future<ConnectResult> connectSshHost(
  SshHost host, {
  ConnectMode mode = ConnectMode.terminal,
  required SshHostKeyVerifier verifyHostKey,
  SshHostKeyVerifier? jumpVerifyHostKey,
  Future<String?> Function()? onPasswordNeeded,
}) async {
  final user = host.user?.trim() ?? '';
  if (user.isEmpty) {
    throw const FormatException('Username cannot be empty');
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
      if (!await f.exists()) {
        throw FormatException('Jump host key file not found:\n$path');
      }
      jumpIdentities = SSHKeyPair.fromPem(await f.readAsString());
    } else {
      jumpIdentities = await _defaultIdentities();
    }

    final jumpSocket = await NoDelaySocket.connect(
      jump.hostname,
      jump.port,
      timeout: const Duration(seconds: 10),
    );

    if (jumpVerifyHostKey == null) {
      jumpSocket.destroy();
      throw const FormatException(
        'Jump host key verifier is required but was not provided',
      );
    }
    jumpClient = SSHClient(
      jumpSocket,
      username: jumpUser,
      identities: jumpIdentities,
      onPasswordRequest: jumpOnPassword,
      onVerifyHostKey: (type, fp) => jumpVerifyHostKey(type, fp),
    );

    try {
      // Catches BOTH the explicit timeout and any other auth-time failure
      // (host-key rejection, password rejection, protocol error) so the
      // half-open SSH session is always closed.
      await jumpClient.authenticated.timeout(
        const Duration(seconds: 15),
        onTimeout: () =>
            throw TimeoutException('Jump host authentication timed out'),
      );
    } catch (_) {
      jumpClient.close();
      rethrow;
    }
  }

  // Everything below this point can throw — wrap so the (already-authenticated)
  // jumpClient is always closed on the failure path.  Previously only the
  // explicit `.timeout(onTimeout:)` callbacks closed it, leaking the SSH
  // session on key-parse errors, default-identity load failures, non-timeout
  // tunnel errors, host-key rejections, and the post-auth execute/sftp paths.
  SSHClient? client;
  try {
    // ── 公钥通道：与密码通道独立 ──────────────────────────────
    List<SSHKeyPair>? identities;
    if (host.identityFile != null && host.identityFile!.isNotEmpty) {
      final path = expandHomePath(host.identityFile!);
      final f = File(path);
      if (!await f.exists()) {
        throw FormatException('Key file not found:\n$path');
      }
      identities = SSHKeyPair.fromPem(await f.readAsString());
      if (identities.isEmpty) {
        throw FormatException('Cannot parse key:\n$path');
      }
    } else {
      identities = await _defaultIdentities();
    }

    // ── 密码通道：与公钥通道独立 ──────────────────────────────
    FutureOr<String?> Function()? onPassword;
    if (host.password != null && host.password!.isNotEmpty) {
      onPassword = () => host.password!;
    } else if (onPasswordNeeded != null) {
      onPassword = onPasswordNeeded;
    }

    // Use tunnel socket when jump host is present, otherwise direct TCP.
    // The timeout branch no longer closes jumpClient itself — the outer
    // catch handles it uniformly for ALL failure modes.
    final socket = jumpClient != null
        ? await jumpClient
              .forwardLocal(host.hostname, host.port)
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  throw TimeoutException('Jump host tunnel timed out');
                },
              )
        : await NoDelaySocket.connect(
            host.hostname,
            host.port,
            timeout: const Duration(seconds: 10),
          );

    client = SSHClient(
      socket,
      username: user,
      identities: identities,
      onPasswordRequest: onPassword,
      onVerifyHostKey: (type, fingerprint) => verifyHostKey(type, fingerprint),
    );

    SSHSession? session;
    SftpClient? sftp;

    if (mode == ConnectMode.terminal) {
      session = await openSshLoginShell(
        client,
      ).timeout(const Duration(seconds: 15));
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
  } catch (_) {
    client?.close();
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

  if (host.isEmpty) throw const FormatException('Enter IP or hostname');
  if (user.isEmpty) throw const FormatException('Username cannot be empty');

  final pwd = password?.trim();
  final keyPath = identityFile?.trim();

  final name = alias?.trim();
  final resolvedAlias = (name != null && name.isNotEmpty)
      ? name
      : (port == 22 ? host : '$host:$port');

  final sshHost = SshHost(
    alias: resolvedAlias,
    hostname: host,
    port: port,
    user: user,
    identityFile: (keyPath != null && keyPath.isNotEmpty)
        ? expandHomePath(keyPath)
        : null,
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
  if (Platform.isIOS) return null;
  final ssh = userSshDir();
  for (final p in ['$ssh/id_ed25519', '$ssh/id_rsa', '$ssh/id_ecdsa']) {
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
