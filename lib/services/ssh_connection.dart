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
      if (!await f.exists()) throw FormatException('Jump host key file not found:\n$path');
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

    await jumpClient.authenticated
        .timeout(const Duration(seconds: 15), onTimeout: () {
      jumpClient!.close();
      throw TimeoutException('Jump host authentication timed out');
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
      throw FormatException('Key file not found:\n$path');
    }
    identities = SSHKeyPair.fromPem(await f.readAsString());
    if (identities.isEmpty) {
      jumpClient?.close();
      throw FormatException('Cannot parse key:\n$path');
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
          throw TimeoutException('Jump host tunnel timed out');
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
          .execute(
            _interactiveShellWrapperCommand(),
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

String _interactiveShellWrapperCommand() {
  return r'''
shell="${SHELL:-/bin/sh}"
shell_name="${shell##*/}"

case "$shell_name" in
  zsh)
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ssterm-zsh.XXXXXX")"
    cat >"$tmpdir/.zshenv" <<'EOF'
if [ -f "$HOME/.zshenv" ]; then
  . "$HOME/.zshenv"
fi
EOF
    cat >"$tmpdir/.zprofile" <<'EOF'
if [ -f "$HOME/.zprofile" ]; then
  . "$HOME/.zprofile"
fi
EOF
    cat >"$tmpdir/.zshrc" <<'EOF'
__ssterm_cwd() {
  printf '\033]7;file://%s\033\\' "$PWD"
}
HISTFILE="$HOME/.zsh_history"
if [ -f "$HOME/.zshrc" ]; then
  . "$HOME/.zshrc"
fi
case " ${precmd_functions[*]} " in
  *" __ssterm_cwd "*) : ;;
  *) precmd_functions+=(__ssterm_cwd) ;;
esac
__ssterm_cwd
EOF
    cat >"$tmpdir/.zlogin" <<'EOF'
if [ -f "$HOME/.zlogin" ]; then
  . "$HOME/.zlogin"
fi
zshexit() { rm -rf "$ZDOTDIR"; }
EOF
    exec env ZDOTDIR="$tmpdir" "$shell" -il
    ;;
  bash)
    rcfile="$(mktemp "${TMPDIR:-/tmp}/ssterm-bash.XXXXXX")"
    cat >"$rcfile" <<'EOF'
__ssterm_cwd() {
  printf '\033]7;file://%s\033\\' "$PWD"
}
if [ -f /etc/profile ]; then
  . /etc/profile
fi
if [ -f "$HOME/.bash_profile" ]; then
  . "$HOME/.bash_profile"
elif [ -f "$HOME/.bash_login" ]; then
  . "$HOME/.bash_login"
elif [ -f "$HOME/.profile" ]; then
  . "$HOME/.profile"
elif [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
case ";${PROMPT_COMMAND:-};" in
  *";__ssterm_cwd;"*) : ;;
  *) PROMPT_COMMAND="__ssterm_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
__ssterm_cwd
# Workaround for Tencent Cloud's custom bash (mupan build): it miscounts the
# visible width of \u/\h/\w when they appear inside the \[\e]0;...\a\] window
# title group, which makes readline redraw long input at the wrong column.
case "$PS1" in
  *'\[\e]0;'*'\a\]'*)
    __ssterm_ps1_before="${PS1%%'\[\e]0;'*}"
    __ssterm_ps1_after="${PS1#*'\a\]'}"
    PS1="${__ssterm_ps1_before}${__ssterm_ps1_after}"
    unset __ssterm_ps1_before __ssterm_ps1_after
    ;;
esac
EOF
    exec "$shell" --noprofile --rcfile "$rcfile" -i
    ;;
  *)
    exec "$shell" -il
    ;;
esac
''';
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
