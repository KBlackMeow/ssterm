import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../models/connect_result.dart';
import '../models/ssh_host.dart';
import '../utils/app_dir.dart';
import 'host_key_verifier.dart';
import 'no_delay_socket.dart';

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
            .timeout(const Duration(seconds: 10), onTimeout: () {
            throw TimeoutException('Jump host tunnel timed out');
          })
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
      session = await client
          .execute(
            interactiveShellWrapperCommand(),
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
  } catch (_) {
    client?.close();
    jumpClient?.close();
    rethrow;
  }
}

/// Shell bootstrap that emits OSC 7 cwd updates for SFTP path sync.
String interactiveShellWrapperCommand() {
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
# Tell the agent which shell binary to use when it needs to wrap a
# multi-line command in `<shell> -c '…'` (so the user shell sees it as a
# single command, emitting one OSC 133 C/D pair).  Without this hint the
# agent would default to `bash`, which is missing on Alpine / Termux /
# zsh-only systems.
export SSTM_SHELL_BIN=zsh
if [ -f "$HOME/.zshrc" ]; then
  . "$HOME/.zshrc"
fi
__ssterm_osc133_preexec() {
  printf '\033]133;C\007'
}
# CRITICAL: must run FIRST in precmd_functions so $? still carries the
# user command's exit code.  Subsequent hooks (case statements, printf)
# overwrite $?, which is why iTerm2 / VS Code shell-integration also
# install their precmd at index 0.  We re-assert the position on every
# call from __ssterm_heal_hooks below.
__ssterm_osc133_precmd() {
  local _ssterm_ec=$?
  printf '\033]133;D;%s\007' "$_ssterm_ec"
  return $_ssterm_ec
}
# Install hooks.  __ssterm_heal_hooks runs on every precmd and restores
# our hooks if a framework (oh-my-zsh) removed them — and forces
# __ssterm_osc133_precmd to be at index 0 of precmd_functions.
__ssterm_heal_hooks() {
  # Force osc133_precmd to be the FIRST precmd hook.  If it is missing
  # OR not at index 1 (zsh arrays are 1-indexed), rebuild the array.
  if [[ "${precmd_functions[1]}" != "__ssterm_osc133_precmd" ]]; then
    precmd_functions=(__ssterm_osc133_precmd ${precmd_functions:#__ssterm_osc133_precmd})
  fi
  case " ${precmd_functions[*]} " in
    *" __ssterm_cwd "*) : ;;
    *) precmd_functions+=(__ssterm_cwd) ;;
  esac
  case " ${preexec_functions[*]} " in
    *" __ssterm_osc133_preexec "*) : ;;
    *) preexec_functions+=(__ssterm_osc133_preexec) ;;
  esac
}
# Run heal_hooks AFTER osc133_precmd so the index-0 invariant is
# established before the first command.  add-zsh-hook isn't used here
# because we want explicit control over ordering.
precmd_functions=(__ssterm_osc133_precmd __ssterm_heal_hooks "${precmd_functions[@]}")
__ssterm_heal_hooks
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
    ENV=/dev/fd/3 exec "$shell" --posix --noprofile -i 3<<'RCEOF'
set +o posix
__ssterm_cwd() {
  printf '\033]7;file://%s\033\\' "$PWD"
}
# Tell the agent's wrapper to use bash when packaging multi-line cmds.
export SSTM_SHELL_BIN=bash
__ssterm_osc133_preexec() {
  printf '\033]133;C\007'
}
# Save $? on entry so any later command in PROMPT_COMMAND can't clobber it.
__ssterm_osc133_precmd() {
  local _ssterm_ec=$?
  printf '\033]133;D;%s\007' "$_ssterm_ec"
  return $_ssterm_ec
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
if [[ ${BASH_VERSINFO[0]} -gt 4 || ( ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 4 ) ]]; then
  PS0='$(__ssterm_osc133_preexec)'
  if ! [[ "$PROMPT_COMMAND" == *__ssterm_osc133_precmd* ]]; then
    PROMPT_COMMAND="__ssterm_osc133_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
  fi
fi
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
RCEOF
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
  if (Platform.isIOS) return null;
  final ssh = userSshDir();
  for (final p in [
    '$ssh/id_ed25519',
    '$ssh/id_rsa',
    '$ssh/id_ecdsa',
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
