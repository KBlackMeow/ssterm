import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'dialogs/connect_dialog.dart';
import 'models/app_config.dart';
import 'models/saved_hosts_store.dart';
import 'models/ssh_config.dart';
import 'models/ssh_host.dart';
import 'services/host_key_verifier.dart';
import 'services/local_shell_discovery.dart';
import 'services/port_forward_service.dart';
import 'services/remote_cwd_parser.dart';
import 'services/remote_home.dart';
import 'services/session_logger.dart';
import 'services/ssh_connection.dart';
import 'views/settings/settings_sheet.dart' show SettingsPage;
import 'widgets/cmd_picker_button.dart';
import 'widgets/split_view.dart';
import 'widgets/terminal_surface.dart'
    show TerminalSurface, TerminalContextMenuConfig;
import 'models/transfer_task.dart';
import 'views/ssh_session_view.dart';
import 'widgets/transfer_panel.dart';

void main() {
  runApp(const SsTermApp());
}

class SsTermApp extends StatelessWidget {
  const SsTermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ssterm',
      debugShowCheckedModeBanner: false,
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: const TerminalHome(),
    );
  }
}

const _kBg = Color(0xFF1C1C1C);
const _kTabBarBg = Color(0xFF2B2B2B);
const _kDivider = Color(0xFF3A3A3A);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);

// ── I/O → Terminal bridge ────────────────────────────────────────────────────
class _OutputPipe {
  _OutputPipe(this._terminal, {this.transform, this.sessionLogger});

  final Terminal _terminal;
  final List<int> Function(List<int>)? transform;
  final SessionLogger? sessionLogger;
  final _buf = BytesBuilder(copy: false);
  Timer? _timer;
  final _subs = <StreamSubscription<List<int>>>[];

  // Cap per-write to keep the main thread unblocked while streaming large output.
  static const _kMaxBytesPerWrite = 65536; // 64 KB
  static const _kFlushInterval = Duration(milliseconds: 16); // ~60 fps

  void bind(Stream<List<int>> stream) {
    _subs.add(stream.listen(_onChunk));
  }

  void _onChunk(List<int> chunk) {
    _buf.add(chunk);
    _timer ??= Timer(_kFlushInterval, _flush);
  }

  void _flush() {
    _timer = null;
    final all = _buf.takeBytes();
    if (all.isEmpty) return;

    final Uint8List toWrite;
    if (all.length > _kMaxBytesPerWrite) {
      toWrite = Uint8List.sublistView(all, 0, _kMaxBytesPerWrite);
      _buf.add(Uint8List.sublistView(all, _kMaxBytesPerWrite));
      _timer = Timer(_kFlushInterval, _flush);
    } else {
      toWrite = all;
    }

    sessionLogger?.write(toWrite);
    List<int> out = toWrite;
    if (transform != null) {
      out = Uint8List.fromList(transform!(toWrite));
    }
    if (out.isNotEmpty) {
      _terminal.write(utf8.decode(out, allowMalformed: true));
    }
  }

  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    sessionLogger?.close();
  }
}

// ── Tab model ────────────────────────────────────────────────────────────────
enum _TabKind { local, ssh, settings }

class _Tab {
  _TabKind kind;
  String title;
  LocalShellOption? localShell;

  // Primary pane
  Terminal? terminal;
  Pty? pty;
  SSHClient? sshClient;
  SSHClient? jumpClient;
  SSHSession? sshSession;
  SftpClient? sftp;
  ValueNotifier<String>? remotePath;
  ValueNotifier<String>? localPath;
  _OutputPipe? pipe;
  final terminalViewKey = GlobalKey<TerminalViewState>();

  // Feature 1: port forwarding
  PortForwardService? forwardService;

  // Feature 4: keepalive + auto-reconnect
  SshHost? sshProfile;
  bool manuallyDisconnected = false;
  Timer? keepaliveTimer;

  // SFTP panel visibility (default hidden)
  bool sftpPanelVisible = false;

  // Transfer manager (created alongside the sftp client)
  TransferManager? transferManager;

  // Feature 3: in-tab split pane
  Terminal? splitTerminal;
  SSHSession? splitSshSession;
  Pty? splitPty;
  _OutputPipe? splitPipe;
  final splitViewKey = GlobalKey<TerminalViewState>();
  Axis splitAxis = Axis.horizontal;

  final terminalController = TerminalController();
  final splitTerminalController = TerminalController();

  /// Primary pane shell/SSH ended; Enter restarts the session.
  bool primarySessionEnded = false;

  /// Split pane shell/SSH ended; Enter restarts the session.
  bool splitSessionEnded = false;

  bool get isSplit => splitTerminal != null;

  _Tab._({
    required this.kind,
    required this.title,
    this.localShell,
    this.terminal,
    this.sshClient,
    this.jumpClient,
    this.sshSession,
    this.sftp,
    this.remotePath,
    this.localPath,
    this.sshProfile,
  });

  factory _Tab.ssh(
    Terminal t,
    SSHClient c,
    SSHSession s,
    String title, {
    SSHClient? jumpClient,
    SftpClient? sftp,
    ValueNotifier<String>? remotePath,
    ValueNotifier<String>? localPath,
    SshHost? profile,
  }) => _Tab._(
    kind: _TabKind.ssh,
    title: title,
    terminal: t,
    sshClient: c,
    jumpClient: jumpClient,
    sshSession: s,
    sftp: sftp,
    remotePath: remotePath,
    localPath: localPath,
    sshProfile: profile,
  );

  factory _Tab.settings() => _Tab._(kind: _TabKind.settings, title: 'Settings');

  void clearSplit() {
    splitPipe?.dispose();
    splitSshSession?.close();
    splitPty?.kill();
    splitTerminal = null;
    splitSshSession = null;
    splitPty = null;
    splitPipe = null;
    splitSessionEnded = false;
  }

  void dispose() {
    manuallyDisconnected = true;
    keepaliveTimer?.cancel();
    keepaliveTimer = null;
    clearSplit();
    pipe?.dispose();
    remotePath?.dispose();
    localPath?.dispose();
    forwardService?.stopAll();
    pty?.kill();
    sshSession?.close();
    sshClient?.close();
    jumpClient?.close();
    terminalController.dispose();
    splitTerminalController.dispose();
    transferManager?.dispose();
  }

  IconData get icon => switch (kind) {
    _TabKind.local => Icons.terminal,
    _TabKind.ssh => Icons.lock_outline,
    _TabKind.settings => Icons.settings_outlined,
  };
}

// ── Home ──────────────────────────────────────────────────────────────────────
class TerminalHome extends StatefulWidget {
  const TerminalHome({super.key});

  @override
  State<TerminalHome> createState() => _TerminalHomeState();
}

class _TerminalHomeState extends State<TerminalHome> {
  final List<_Tab> _tabs = [];
  int _active = 0;
  List<SshHost> _savedHosts = [];
  List<SshHost> _configHosts = [];
  List<LocalShellOption> _localShells = LocalShellDiscovery.discoverSync();
  AppConfig _config = AppConfig();

  @override
  void initState() {
    super.initState();
    _newLocalTab(LocalShellDiscovery.defaultShell(_localShells));
    _refreshLocalShells();
    _loadSshHosts();
    AppConfig.load().then((c) {
      if (mounted) setState(() => _config = c);
    });
  }

  Future<List<LocalShellOption>> _refreshLocalShells() async {
    final shells = await LocalShellDiscovery.discover(refresh: true);
    if (!mounted) return _localShells;
    setState(() => _localShells = shells);
    return shells;
  }

  Future<void> _loadSshHosts() async {
    final saved = await SavedHostsStore.load();
    final config = await parseSshConfig();
    if (!mounted) return;
    setState(() {
      _savedHosts = saved
        ..sort(
          (a, b) => a.alias.toLowerCase().compareTo(b.alias.toLowerCase()),
        );
      _configHosts = config
        ..sort(
          (a, b) => a.alias.toLowerCase().compareTo(b.alias.toLowerCase()),
        );
    });
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  // ── Local terminal ─────────────────────────────────────────────────────────

  Terminal _createTerminal({bool reflowEnabled = true}) => Terminal(
    maxLines: 5000,
    platform: detectTerminalHostPlatform(),
    reflowEnabled: reflowEnabled,
  );

  Map<String, String> _environmentForLocalShell(LocalShellOption shell) {
    // WSL must not inherit Windows SHELL/PATH — a value like
    // C:\Windows\System32\wsl.exe breaks zsh/bash inside the distro.
    if (shell.isWsl) {
      return _wslEnvironment(shell);
    }

    if (shell.id.startsWith('git-bash')) {
      return _gitBashEnvironment(shell);
    }

    final env = Map<String, String>.from(Platform.environment)
      ..['TERM'] = 'xterm-256color'
      ..['COLORTERM'] = 'truecolor'
      ..['TERM_PROGRAM'] = 'ssterm';
    if (shell.environment != null) {
      env.addAll(shell.environment!);
    }
    if (shell.useUnixWrapper) {
      env['SHELL'] = shell.executable;
    }
    return env;
  }

  Map<String, String> _wslEnvironment(LocalShellOption shell) {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final env = <String, String>{
      'SSTERM_EXACT_ENV': '1',
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'TERM_PROGRAM': 'ssterm',
      // Empty WSLENV prevents WSL from translating any Windows env vars
      // (notably SHELL=C:\Windows\System32\wsl.exe) into the Linux session.
      'WSLENV': '',
      'SystemRoot': systemRoot,
      'WINDIR': Platform.environment['WINDIR'] ?? systemRoot,
      'PATH': [
        '$systemRoot\\System32',
        systemRoot,
        '$systemRoot\\System32\\Wbem',
        '$systemRoot\\System32\\WindowsPowerShell\\v1.0',
      ].join(';'),
    };

    for (final key in const [
      'APPDATA',
      'LOCALAPPDATA',
      'ProgramData',
      'ProgramFiles',
      'ProgramFiles(x86)',
      'PUBLIC',
      'TEMP',
      'TMP',
      'USERNAME',
      'USERDOMAIN',
      'USERPROFILE',
    ]) {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) {
        env[key] = value;
      }
    }

    return env;
  }

  Map<String, String> _gitBashEnvironment(LocalShellOption shell) {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final userProfile = Platform.environment['USERPROFILE'];
    final gitRoot = shell.executable
        .replaceFirst(
          RegExp(r'\\usr\\bin\\env\.exe$', caseSensitive: false),
          '',
        )
        .replaceFirst(RegExp(r'\\bin\\bash\.exe$', caseSensitive: false), '');
    final path = [
      if (gitRoot != shell.executable) ...[
        '$gitRoot\\usr\\bin',
        '$gitRoot\\mingw64\\bin',
        '$gitRoot\\bin',
      ],
      '$systemRoot\\System32',
      systemRoot,
    ].join(';');

    final env = <String, String>{
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'TERM_PROGRAM': 'ssterm',
      'SystemRoot': systemRoot,
      'WINDIR': systemRoot,
      'PATH': path,
      'MSYSTEM': 'MINGW64',
      'MSYS': 'enable_pcon winsymlink:nativestrict',
      'CHERE_INVOKING': '1',
      'SHELL': '/usr/bin/bash',
    };

    final username = Platform.environment['USERNAME'];
    final temp = Platform.environment['TEMP'];
    final tmp = Platform.environment['TMP'];
    if (username != null) env['USERNAME'] = username;
    if (userProfile != null) {
      env['USERPROFILE'] = userProfile;
      env['HOME'] = userProfile;
    }
    if (temp != null) env['TEMP'] = temp;
    if (tmp != null) env['TMP'] = tmp;
    if (shell.environment != null) {
      env.addAll(shell.environment!);
      env['SHELL'] = '/usr/bin/bash';
    }
    return env;
  }

  static const _kRestartPrompt = '\r\nPress Enter to restart.\r\n';

  static bool _isRestartKey(String data) {
    if (data.isEmpty) return false;
    return data.codeUnits.every((c) => c == 0x0d || c == 0x0a);
  }

  void _bindTerminalInput(
    Terminal terminal,
    _Tab tab, {
    required bool isSplit,
    required void Function(String data) forward,
  }) {
    terminal.onOutput = (data) {
      final ended =
          isSplit ? tab.splitSessionEnded : tab.primarySessionEnded;
      if (ended) {
        if (_isRestartKey(data)) {
          unawaited(_restartSession(tab, isSplit: isSplit));
        }
        return;
      }
      forward(data);
    };
  }

  Future<void> _restartSession(_Tab tab, {required bool isSplit}) async {
    final ended =
        isSplit ? tab.splitSessionEnded : tab.primarySessionEnded;
    if (!ended || !mounted) return;

    final terminal = isSplit ? tab.splitTerminal : tab.terminal;
    if (terminal == null) return;

    if (isSplit) {
      tab.splitSessionEnded = false;
    } else {
      tab.primarySessionEnded = false;
    }

    if (tab.kind == _TabKind.local) {
      final shell =
          tab.localShell ?? LocalShellDiscovery.defaultShell(_localShells);
      final cwd = tab.localPath?.value;
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      _spawnLocalPty(
        tab: tab,
        terminal: terminal,
        shell: shell,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
        workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : home,
        isSplit: isSplit,
      );
    } else if (tab.kind == _TabKind.ssh) {
      await _restartSshShell(tab, terminal: terminal, isSplit: isSplit);
    }
  }

  void _spawnLocalPty({
    required _Tab tab,
    required Terminal terminal,
    required LocalShellOption shell,
    required int columns,
    required int rows,
    String? workingDirectory,
    required bool isSplit,
    bool showExitMessage = true,
  }) {
    if (columns < 1 || rows < 1) return;

    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final env = _environmentForLocalShell(shell);
    final useUnixWrapper = shell.useUnixWrapper && !Platform.isWindows;

    final Pty pty;
    if (useUnixWrapper) {
      pty = Pty.start(
        '/bin/sh',
        arguments: ['-lc', _interactiveLocalShellWrapperCommand()],
        columns: columns,
        rows: rows,
        environment: env,
        workingDirectory: workingDirectory ?? home,
      );
    } else {
      pty = Pty.start(
        shell.executable,
        arguments: shell.arguments,
        columns: columns,
        rows: rows,
        environment: env,
        workingDirectory: shell.isWsl ? null : (workingDirectory ?? home),
      );
    }

    if (isSplit) {
      tab.splitPty?.kill();
      tab.splitPty = pty;
    } else {
      tab.pty?.kill();
      tab.pty = pty;
    }

    final cwdParser = RemoteCwdParser();
    final pipe = _OutputPipe(
      terminal,
      transform: (bytes) {
        final parsed = cwdParser.process(bytes);
        if (parsed.cwd != null && tab.localPath != null) {
          tab.localPath!.value = parsed.cwd!;
        }
        return parsed.cleaned;
      },
    )..bind(pty.output);

    if (isSplit) {
      tab.splitPipe?.dispose();
      tab.splitPipe = pipe;
    } else {
      tab.pipe?.dispose();
      tab.pipe = pipe;
    }

    _bindTerminalInput(
      terminal,
      tab,
      isSplit: isSplit,
      forward: (d) => pty.write(utf8.encode(d)),
    );

    pty.exitCode.then((code) {
      if (!mounted) return;
      if (showExitMessage) {
        terminal.write('\r\n[Process exited with code $code]\r\n');
      }
      terminal.write(_kRestartPrompt);
      if (isSplit) {
        tab.splitSessionEnded = true;
        tab.splitPty = null;
        tab.splitPipe?.dispose();
        tab.splitPipe = null;
      } else {
        tab.primarySessionEnded = true;
        tab.pty = null;
        tab.pipe?.dispose();
        tab.pipe = null;
      }
    });
  }

  /// Start the local PTY on the first [Terminal.onResize] so rows/cols match the
  /// pane instead of a hard-coded 80×24.
  void _wireDeferredLocalPty(
    _Tab tab, {
    required Terminal terminal,
    required LocalShellOption shell,
    String? workingDirectory,
    required bool isSplit,
    bool showExitMessage = true,
  }) {
    terminal.onResize = (w, h, pw, ph) {
      if (w < 1 || h < 1) return;
      final activePty = isSplit ? tab.splitPty : tab.pty;
      final ended =
          isSplit ? tab.splitSessionEnded : tab.primarySessionEnded;
      if (activePty == null && !ended) {
        _spawnLocalPty(
          tab: tab,
          terminal: terminal,
          shell: shell,
          columns: w,
          rows: h,
          workingDirectory: workingDirectory,
          isSplit: isSplit,
          showExitMessage: showExitMessage,
        );
      } else if (activePty != null) {
        activePty.resize(h, w);
      }
    };
  }

  Future<void> _handleSshSessionDone(
    _Tab tab,
    Terminal terminal, {
    required bool isSplit,
    SshHost? profile,
  }) async {
    if (!isSplit) {
      tab.keepaliveTimer?.cancel();
      tab.keepaliveTimer = null;
    }
    if (!mounted || tab.manuallyDisconnected) return;

    final prof = profile ?? tab.sshProfile;
    if (!isSplit && prof != null && prof.autoReconnect) {
      terminal.write('\r\n[SSH connection closed]\r\n');
      terminal.write('[Reconnecting in 3 seconds…]\r\n');
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted || tab.manuallyDisconnected) return;
      await _reconnectTab(tab);
      return;
    }

    if (isSplit) {
      tab.splitSshSession?.close();
      tab.splitSshSession = null;
      tab.splitPipe?.dispose();
      tab.splitPipe = null;
      tab.splitSessionEnded = true;
    } else {
      tab.sshSession?.close();
      tab.sshSession = null;
      tab.pipe?.dispose();
      tab.pipe = null;
      tab.primarySessionEnded = true;
    }
    terminal.write('\r\n[SSH connection closed]\r\n');
    terminal.write(_kRestartPrompt);
  }

  Future<void> _restartSshShell(
    _Tab tab, {
    required Terminal terminal,
    required bool isSplit,
  }) async {
    final client = tab.sshClient;
    if (client == null) {
      if (!isSplit && tab.sshProfile != null) {
        await _reconnectTab(tab);
      } else {
        terminal.write('[Not connected]\r\n$_kRestartPrompt');
        if (isSplit) {
          tab.splitSessionEnded = true;
        } else {
          tab.primarySessionEnded = true;
        }
      }
      return;
    }

    try {
      final session = await client
          .shell(
            pty: SSHPtyConfig(
              width: terminal.viewWidth,
              height: terminal.viewHeight,
              type: 'xterm-256color',
            ),
          )
          .timeout(const Duration(seconds: 15));

      final cwdParser = RemoteCwdParser();
      final pipe = _OutputPipe(
        terminal,
        transform: (bytes) {
          final parsed = cwdParser.process(bytes);
          if (parsed.cwd != null && tab.remotePath != null) {
            tab.remotePath!.value = parsed.cwd!;
          }
          return parsed.cleaned;
        },
      );

      _bindTerminalInput(
        terminal,
        tab,
        isSplit: isSplit,
        forward: (d) => session.stdin.add(utf8.encode(d)),
      );
      terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);

      pipe.bind(session.stdout);
      pipe.bind(session.stderr);

      if (isSplit) {
        tab.splitSshSession?.close();
        tab.splitSshSession = session;
        tab.splitPipe?.dispose();
        tab.splitPipe = pipe;
      } else {
        tab.sshSession?.close();
        tab.sshSession = session;
        tab.pipe?.dispose();
        tab.pipe = pipe;
      }

      session.done.then(
        (_) => _handleSshSessionDone(tab, terminal, isSplit: isSplit),
      );
    } catch (e) {
      if (!mounted) return;
      terminal.write('[Reconnect failed: $e]\r\n$_kRestartPrompt');
      if (isSplit) {
        tab.splitSessionEnded = true;
      } else {
        tab.primarySessionEnded = true;
      }
    }
  }

  void _wireSshSession(
    _Tab tab,
    SSHSession session,
    Terminal terminal,
    _OutputPipe pipe, {
    required bool isSplit,
    SshHost? profile,
  }) {
    _bindTerminalInput(
      terminal,
      tab,
      isSplit: isSplit,
      forward: (d) => session.stdin.add(utf8.encode(d)),
    );
    terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);
    session.done.then(
      (_) => _handleSshSessionDone(
        tab,
        terminal,
        isSplit: isSplit,
        profile: profile,
      ),
    );
  }

  String _interactiveLocalShellWrapperCommand() {
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
EOF
    exec "$shell" --noprofile --rcfile "$rcfile" -i
    ;;
  *)
    exec "$shell" -i
    ;;
esac
''';
  }

  void _newLocalTab(LocalShellOption shell) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final tab = _Tab._(
      kind: _TabKind.local,
      title: shell.displayName,
      localShell: shell,
      terminal: _createTerminal(),
      localPath: ValueNotifier<String>(home ?? '/'),
    );
    _wireDeferredLocalPty(
      tab,
      terminal: tab.terminal!,
      shell: shell,
      workingDirectory: home,
      isSplit: false,
    );

    setState(() {
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
    _activateTab(_active);
  }

  // ── SSH / SFTP ─────────────────────────────────────────────────────────────

  Future<void> _showConnectDialog({SshHost? initialHost}) async {
    final result = await showConnectDialog(context, initialHost: initialHost);
    if (result == null || !mounted) return;
    await _rememberHostProfile(result.profile);
    await _openSshTerminal(result);
  }

  Future<void> _rememberHostProfile(SshHost profile) async {
    try {
      await SavedHostsStore.upsert(profile);
    } catch (_) {}
    await _loadSshHosts();
  }

  Future<void> _saveSavedHost(SshHost? original, SshHost updated) async {
    final hosts = await SavedHostsStore.load();
    if (original != null) {
      hosts.removeWhere((h) => h.profileKey == original.profileKey);
    }
    hosts.removeWhere((h) => h.profileKey == updated.profileKey);
    hosts.add(updated);
    await SavedHostsStore.save(hosts);
    if (mounted) await _loadSshHosts();
  }

  Future<void> _deleteSavedHost(SshHost host) async {
    final hosts = await SavedHostsStore.load();
    hosts.removeWhere((h) => h.profileKey == host.profileKey);
    await SavedHostsStore.save(hosts);
    if (mounted) await _loadSshHosts();
  }

  Future<void> _connectSavedHost(SshHost host) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            color: Color(0xFF2B2B2B),
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Color(0xFF2472C8),
                    strokeWidth: 2,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Connecting…',
                    style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      final result = await connectSshHost(
        host,
        verifyHostKey: createHostKeyVerifier(
          context,
          hostname: host.hostname,
          port: host.port,
        ),
        jumpVerifyHostKey: host.jumpHost != null
            ? createHostKeyVerifier(
                context,
                hostname: host.jumpHost!.hostname,
                port: host.jumpHost!.port,
              )
            : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await _loadSshHosts();
      await _openSshTerminal(result);
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop();
      await _showConnectDialog(initialHost: host);
    }
  }

  Future<void> _openSshTerminal(ConnectResult r) async {
    final terminal = _createTerminal(reflowEnabled: false);
    final session = r.session!;
    final remotePath = ValueNotifier<String>('');
    final cwdParser = RemoteCwdParser();

    SessionLogger? logger;
    if (r.profile.sessionLog) {
      try {
        logger = await SessionLogger.create(r.alias);
      } catch (_) {}
    }

    final pipe = _OutputPipe(
      terminal,
      sessionLogger: logger,
      transform: (bytes) {
        final parsed = cwdParser.process(bytes);
        if (parsed.cwd != null && parsed.cwd != remotePath.value) {
          remotePath.value = parsed.cwd!;
        }
        return parsed.cleaned;
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      pipe.bind(session.stdout);
      pipe.bind(session.stderr);
    });

    SftpClient? sftp;
    TransferManager? transferManager;
    try {
      sftp = await r.client.sftp();
      transferManager = TransferManager();
      remotePath.value = await fetchRemoteHome(r.client);
    } catch (_) {
      remotePath.value = '/';
    }

    if (!mounted) {
      pipe.dispose();
      remotePath.dispose();
      return;
    }

    late _Tab tab;
    tab = _Tab.ssh(
      terminal,
      r.client,
      session,
      r.alias,
      jumpClient: r.jumpClient,
      sftp: sftp,
      remotePath: remotePath,
      profile: r.profile,
    );
    tab.pipe = pipe;
    tab.transferManager = transferManager;

    _wireSshSession(
      tab,
      session,
      terminal,
      pipe,
      isSplit: false,
      profile: r.profile,
    );

    // Feature 1: port forwarding
    if (r.profile.forwardRules.isNotEmpty) {
      final fwdService = PortForwardService();
      tab.forwardService = fwdService;
      fwdService.startAll(r.client, r.profile.forwardRules).ignore();
    }

    // Feature 4: keepalive
    if (r.profile.keepaliveInterval > 0) {
      tab.keepaliveTimer = Timer.periodic(
        Duration(seconds: r.profile.keepaliveInterval),
        (_) async {
          try {
            await r.client.run('true').timeout(const Duration(seconds: 5));
          } catch (_) {}
        },
      );
    }

    setState(() {
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
    _activateTab(_active);
  }

  // ── Feature 3: In-tab split pane ──────────────────────────────────────────

  Future<void> _splitCurrentTab(Axis axis) async {
    final tab = _tabs[_active];
    if (tab.isSplit) {
      // Toggle off if same axis, switch axis otherwise
      if (tab.splitAxis == axis) {
        setState(() => tab.clearSplit());
        return;
      } else {
        setState(() => tab.splitAxis = axis);
        return;
      }
    }

    if (tab.kind == _TabKind.ssh && tab.sshClient != null) {
      await _openSshSplitPane(tab, axis);
    } else if (tab.kind == _TabKind.local) {
      _openLocalSplitPane(tab, axis);
    }
  }

  Future<void> _openSshSplitPane(_Tab tab, Axis axis) async {
    final splitTerminal = _createTerminal(reflowEnabled: false);
    SSHSession session;
    try {
      session = await tab.sshClient!
          .shell(
            pty: const SSHPtyConfig(
              width: 80,
              height: 24,
              type: 'xterm-256color',
            ),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return;
    }

    final cwdParser = RemoteCwdParser();
    final pipe = _OutputPipe(
      splitTerminal,
      transform: (bytes) => cwdParser.process(bytes).cleaned,
    );

    _wireSshSession(tab, session, splitTerminal, pipe, isSplit: true);

    pipe.bind(session.stdout);
    pipe.bind(session.stderr);

    if (!mounted) {
      pipe.dispose();
      session.close();
      return;
    }

    setState(() {
      tab.splitTerminal = splitTerminal;
      tab.splitSshSession = session;
      tab.splitPipe = pipe;
      tab.splitAxis = axis;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      tab.splitViewKey.currentState?.syncAfterShown();
    });
  }

  void _openLocalSplitPane(_Tab tab, Axis axis) {
    final shell =
        tab.localShell ?? LocalShellDiscovery.defaultShell(_localShells);
    final splitTerminal = _createTerminal();
    final cwd = tab.localPath?.value;
    _wireDeferredLocalPty(
      tab,
      terminal: splitTerminal,
      shell: shell,
      workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : null,
      isSplit: true,
      showExitMessage: false,
    );

    setState(() {
      tab.splitTerminal = splitTerminal;
      tab.splitAxis = axis;
      tab.splitSessionEnded = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      tab.splitViewKey.currentState?.syncAfterShown();
    });
  }

  void _closeSplitCurrentTab() {
    if (_active < _tabs.length) {
      setState(() => _tabs[_active].clearSplit());
    }
  }

  // ── Feature 4: reconnect ───────────────────────────────────────────────────

  Future<void> _reconnectTab(_Tab tab) async {
    final profile = tab.sshProfile;
    if (profile == null || !mounted) return;

    tab.terminal?.write('[Reconnecting to ${profile.alias}…]\r\n');

    try {
      final result = await connectSshHost(
        profile,
        verifyHostKey: createHostKeyVerifier(
          context,
          hostname: profile.hostname,
          port: profile.port,
        ),
        jumpVerifyHostKey: profile.jumpHost != null
            ? createHostKeyVerifier(
                context,
                hostname: profile.jumpHost!.hostname,
                port: profile.jumpHost!.port,
              )
            : null,
      );
      if (!mounted || tab.manuallyDisconnected) {
        result.client.close();
        result.jumpClient?.close();
        return;
      }

      final oldSession = tab.sshSession;
      final oldClient = tab.sshClient;
      final oldJump = tab.jumpClient;
      tab.keepaliveTimer?.cancel();
      tab.forwardService?.stopAll();
      tab.clearSplit();

      final session = result.session!;
      final cwdParser = RemoteCwdParser();

      SessionLogger? logger;
      if (profile.sessionLog) {
        try {
          logger = await SessionLogger.create(profile.alias);
        } catch (_) {}
      }

      final pipe = _OutputPipe(
        tab.terminal!,
        sessionLogger: logger,
        transform: (bytes) {
          final parsed = cwdParser.process(bytes);
          if (parsed.cwd != null) tab.remotePath?.value = parsed.cwd!;
          return parsed.cleaned;
        },
      );

      tab.primarySessionEnded = false;
      _wireSshSession(
        tab,
        session,
        tab.terminal!,
        pipe,
        isSplit: false,
        profile: profile,
      );

      WidgetsBinding.instance.addPostFrameCallback((_) {
        pipe.bind(session.stdout);
        pipe.bind(session.stderr);
      });

      tab.pipe?.dispose();
      tab.pipe = pipe;
      tab.sshSession = session;
      tab.sshClient = result.client;
      tab.jumpClient = result.jumpClient;

      oldSession?.close();
      oldClient?.close();
      oldJump?.close();

      if (profile.forwardRules.isNotEmpty) {
        final fwdService = PortForwardService();
        tab.forwardService = fwdService;
        fwdService.startAll(result.client, profile.forwardRules).ignore();
      }

      if (profile.keepaliveInterval > 0) {
        tab.keepaliveTimer = Timer.periodic(
          Duration(seconds: profile.keepaliveInterval),
          (_) async {
            try {
              await result.client
                  .run('true')
                  .timeout(const Duration(seconds: 5));
            } catch (_) {}
          },
        );
      }

      tab.terminal?.write('[Reconnected]\r\n');
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        tab.terminal?.write('[Reconnect failed: $e]\r\n$_kRestartPrompt');
        tab.primarySessionEnded = true;
        if (tab.sshProfile?.autoReconnect == true &&
            !tab.manuallyDisconnected) {
          await Future<void>.delayed(const Duration(seconds: 5));
          if (!mounted || tab.manuallyDisconnected) return;
          _reconnectTab(tab);
        }
      }
    }
  }

  // ── Tab management ─────────────────────────────────────────────────────────

  void _closeTab(int i) {
    _tabs[i].dispose();
    if (_tabs.length == 1) {
      exit(0);
    }
    setState(() {
      _tabs.removeAt(i);
      _active = _active.clamp(0, _tabs.length - 1);
    });
    _activateTab(_active);
  }

  void _selectTab(int i) {
    if (i == _active) return;
    setState(() => _active = i);
    _activateTab(i);
  }

  void _activateTab(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i < 0 || i >= _tabs.length) return;
      _tabs[i].terminalViewKey.currentState?.syncAfterShown();
    });
  }

  void _syncAllTerminals() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final tab in _tabs) {
        tab.terminalViewKey.currentState?.syncAfterShown();
        if (tab.isSplit) {
          tab.splitViewKey.currentState?.syncAfterShown();
        }
      }
    });
  }

  void _insertCommand(String cmd) {
    _tabs[_active].terminal?.paste(cmd);
  }

  void _openSettings() {
    final idx = _tabs.indexWhere((t) => t.kind == _TabKind.settings);
    if (idx != -1) {
      _selectTab(idx);
      return;
    }
    setState(() {
      _tabs.add(_Tab.settings());
      _active = _tabs.length - 1;
    });
  }

  Widget _buildTerminalView(
    Terminal terminal,
    GlobalKey<TerminalViewState> viewKey, {
    TerminalContextMenuConfig? contextMenu,
  }) {
    return TerminalSurface(
      terminal: terminal,
      settings: _config.terminal,
      viewKey: viewKey,
      contextMenu: contextMenu,
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  bool get _activeTabCanSplit {
    if (_tabs.isEmpty || _active >= _tabs.length) return false;
    final kind = _tabs[_active].kind;
    return kind == _TabKind.local || kind == _TabKind.ssh;
  }

  bool get _activeTabIsSplit =>
      _tabs.isNotEmpty && _active < _tabs.length && _tabs[_active].isSplit;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.comma):
            const _OpenSettingsIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyW):
            const _CloseTabIntent(),
      },
      child: Actions(
        actions: {
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
            onInvoke: (_) {
              _openSettings();
              return null;
            },
          ),
          _CloseTabIntent: CallbackAction<_CloseTabIntent>(
            onInvoke: (_) {
              _closeTab(_active);
              return null;
            },
          ),
        },
        child: Scaffold(
          backgroundColor: _kBg,
          body: Column(
            children: [
              _TabBar(
                tabs: _tabs,
                active: _active,
                onSelect: _selectTab,
                onClose: _closeTab,
                onNewLocal: _newLocalTab,
                onRefreshLocalShells: _refreshLocalShells,
                onNewSsh: () => _showConnectDialog(),
                onSettings: _openSettings,
                savedHosts: _savedHosts,
                configHosts: _configHosts,
                onConnectHost: _connectSavedHost,
                onInsertCommand:
                    _tabs.isNotEmpty && _tabs[_active].terminal != null
                    ? _insertCommand
                    : null,
                hasSftp:
                    _tabs.isNotEmpty &&
                    _active < _tabs.length &&
                    _tabs[_active].sftp != null,
                sftpVisible:
                    _tabs.isNotEmpty &&
                    _active < _tabs.length &&
                    _tabs[_active].sftpPanelVisible,
                onToggleSftp: () {
                  if (_tabs.isNotEmpty && _active < _tabs.length) {
                    setState(
                      () => _tabs[_active].sftpPanelVisible =
                          !_tabs[_active].sftpPanelVisible,
                    );
                  }
                },
                transferManager: _tabs.isNotEmpty && _active < _tabs.length
                    ? _tabs[_active].transferManager
                    : null,
                canSplit: _activeTabCanSplit,
                isSplit: _activeTabIsSplit,
                splitAxis: _activeTabIsSplit ? _tabs[_active].splitAxis : null,
                onSplitHorizontal: () => _splitCurrentTab(Axis.horizontal),
                onSplitVertical: () => _splitCurrentTab(Axis.vertical),
                onCloseSplit: _closeSplitCurrentTab,
              ),
              const Divider(height: 1, thickness: 1, color: _kDivider),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryContent(
    _Tab tab, {
    TerminalContextMenuConfig? contextMenu,
  }) {
    return switch (tab.kind) {
      _TabKind.local || _TabKind.ssh => _buildTerminalView(
        tab.terminal!,
        tab.terminalViewKey,
        contextMenu: contextMenu,
      ),
      _TabKind.settings => SettingsPage(
        settings: _config.terminal,
        onChanged: (next) {
          setState(() => _config.terminal = next);
          _config.save();
          _syncAllTerminals();
        },
        savedHosts: _savedHosts,
        onSaveHost: (original, updated) => _saveSavedHost(original, updated),
        onDeleteHost: (host) => _deleteSavedHost(host),
      ),
    };
  }

  Widget _buildTabBody(_Tab tab) {
    final canSplit = tab.kind == _TabKind.local || tab.kind == _TabKind.ssh;

    final primaryMenu = TerminalContextMenuConfig(
      controller: tab.terminalController,
      canSplit: canSplit,
      isSplit: tab.isSplit,
      onSplitHorizontal: () => _splitCurrentTab(Axis.horizontal),
      onSplitVertical: () => _splitCurrentTab(Axis.vertical),
      onCloseSplit: _closeSplitCurrentTab,
    );

    Widget body = _buildPrimaryContent(tab, contextMenu: primaryMenu);

    if (tab.isSplit) {
      final splitMenu = TerminalContextMenuConfig(
        controller: tab.splitTerminalController,
        canSplit: canSplit,
        isSplit: true,
        onSplitHorizontal: () => _splitCurrentTab(Axis.horizontal),
        onSplitVertical: () => _splitCurrentTab(Axis.vertical),
        onCloseSplit: _closeSplitCurrentTab,
      );
      body = SplitView(
        primary: body,
        secondary: _buildTerminalView(
          tab.splitTerminal!,
          tab.splitViewKey,
          contextMenu: splitMenu,
        ),
        axis: tab.splitAxis,
      );
    }

    if (tab.kind == _TabKind.ssh &&
        tab.sftp != null &&
        tab.transferManager != null) {
      body = SshSessionView(
        sftp: tab.sftp!,
        host: tab.title,
        remotePath: tab.remotePath!,
        transferManager: tab.transferManager!,
        sftpVisible: tab.sftpPanelVisible,
        onToggleSftp: () =>
            setState(() => tab.sftpPanelVisible = !tab.sftpPanelVisible),
        initialPosition: _config.sftpPosition,
        initialSize: _config.sftpSize,
        onLayoutChanged: (pos, size) {
          _config.sftpPosition = pos;
          _config.sftpSize = size;
          _config.save();
        },
        child: body,
      );
    }

    return body;
  }

  Widget _buildBody() {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    return IndexedStack(
      index: _active,
      sizing: StackFit.expand,
      children: [for (final tab in _tabs) _buildTabBody(tab)],
    );
  }
}

// ── Tab bar ───────────────────────────────────────────────────────────────────
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNewLocal,
    required this.onRefreshLocalShells,
    required this.onNewSsh,
    required this.onSettings,
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
    required this.hasSftp,
    required this.sftpVisible,
    required this.onToggleSftp,
    this.transferManager,
    required this.canSplit,
    required this.isSplit,
    this.splitAxis,
    required this.onSplitHorizontal,
    required this.onSplitVertical,
    required this.onCloseSplit,
    this.onInsertCommand,
  });

  final List<_Tab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final ValueChanged<LocalShellOption> onNewLocal;
  final Future<List<LocalShellOption>> Function() onRefreshLocalShells;
  final VoidCallback onNewSsh;
  final VoidCallback onSettings;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<SshHost> onConnectHost;
  final ValueChanged<String>? onInsertCommand;
  final bool hasSftp;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final TransferManager? transferManager;
  final bool canSplit;
  final bool isSplit;
  final Axis? splitAxis;
  final VoidCallback onSplitHorizontal;
  final VoidCallback onSplitVertical;
  final VoidCallback onCloseSplit;

  static const _preferredTabWidth = 160.0;
  static const _minTabWidth = 80.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      color: _kTabBarBg,
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (tabs.isEmpty) return const SizedBox.shrink();

                final equalWidth = constraints.maxWidth / tabs.length;
                final tabWidth =
                    equalWidth.clamp(_minTabWidth, _preferredTabWidth);
                final needsScroll =
                    tabWidth <= _minTabWidth &&
                    tabs.length * _minTabWidth > constraints.maxWidth;

                final chips = [
                  for (var i = 0; i < tabs.length; i++)
                    SizedBox(
                      width: needsScroll ? _minTabWidth : tabWidth,
                      child: _TabChip(
                        tab: tabs[i],
                        isActive: i == active,
                        showClose: true,
                        expand: true,
                        onTap: () => onSelect(i),
                        onClose: () => onClose(i),
                      ),
                    ),
                ];

                return needsScroll
                    ? SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: chips),
                      )
                    : Row(children: chips);
              },
            ),
          ),
          _PlusMenu(
            onNewLocal: onNewLocal,
            onRefreshLocalShells: onRefreshLocalShells,
            onNewSsh: onNewSsh,
            savedHosts: savedHosts,
            configHosts: configHosts,
            onConnectHost: onConnectHost,
          ),
          CmdPickerButton(onInsert: onInsertCommand),
          if (hasSftp) ...[
            _SftpButton(sftpVisible: sftpVisible, onToggle: onToggleSftp),
            if (transferManager != null)
              _TransferButton(manager: transferManager!),
          ],
          _SplitButton(
            canSplit: canSplit,
            isSplit: isSplit,
            splitAxis: splitAxis,
            onSplitHorizontal: onSplitHorizontal,
            onSplitVertical: onSplitVertical,
            onCloseSplit: onCloseSplit,
          ),
          GestureDetector(
            onTap: onSettings,
            child: Tooltip(
              message: 'Settings (⌘,)',
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.settings_outlined,
                  size: 15,
                  color: _kFgInactive,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

// ── SFTP toggle button ────────────────────────────────────────────────────────
class _SftpButton extends StatelessWidget {
  const _SftpButton({required this.sftpVisible, required this.onToggle});

  final bool sftpVisible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: sftpVisible ? 'Hide SFTP' : 'Show SFTP',
      child: GestureDetector(
        onTap: onToggle,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(
            Icons.folder_outlined,
            size: 15,
            color: sftpVisible ? const Color(0xFF2472C8) : _kFgInactive,
          ),
        ),
      ),
    );
  }
}

// ── Transfer menu button ──────────────────────────────────────────────────────
class _TransferButton extends StatelessWidget {
  const _TransferButton({required this.manager});

  final TransferManager manager;

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
      color: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: _kDivider),
      ),
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 300),
      items: [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: TransferMenuContent(manager: manager),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (ctx, _) {
        final activeCount = manager.activeCount;
        return Tooltip(
          message: 'Transfers',
          child: GestureDetector(
            onTap: () => _showMenu(ctx),
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.swap_vert, size: 15, color: _kFgInactive),
                  if (activeCount > 0)
                    Positioned(
                      right: -4,
                      top: -3,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2472C8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$activeCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Split button ──────────────────────────────────────────────────────────────
class _SplitButton extends StatelessWidget {
  const _SplitButton({
    required this.canSplit,
    required this.isSplit,
    this.splitAxis,
    required this.onSplitHorizontal,
    required this.onSplitVertical,
    required this.onCloseSplit,
  });

  final bool canSplit;
  final bool isSplit;
  final Axis? splitAxis;
  final VoidCallback onSplitHorizontal;
  final VoidCallback onSplitVertical;
  final VoidCallback onCloseSplit;

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
      color: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: _kDivider),
      ),
      items: [
        PopupMenuItem(
          value: 'h',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.vertical_split, size: 13, color: _kFgInactive),
              const SizedBox(width: 8),
              Text(
                'Split horizontal',
                style: TextStyle(
                  color: splitAxis == Axis.horizontal
                      ? const Color(0xFF2472C8)
                      : _kFgActive,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'v',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.splitscreen, size: 13, color: _kFgInactive),
              const SizedBox(width: 8),
              Text(
                'Split vertical',
                style: TextStyle(
                  color: splitAxis == Axis.vertical
                      ? const Color(0xFF2472C8)
                      : _kFgActive,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        if (isSplit)
          const PopupMenuItem(
            value: 'close',
            height: 36,
            child: Row(
              children: [
                Icon(Icons.close, size: 13, color: _kFgInactive),
                SizedBox(width: 8),
                Text(
                  'Close split',
                  style: TextStyle(color: _kFgActive, fontSize: 13),
                ),
              ],
            ),
          ),
      ],
    ).then((v) {
      if (v == 'h') onSplitHorizontal();
      if (v == 'v') onSplitVertical();
      if (v == 'close') onCloseSplit();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Split',
      child: GestureDetector(
        onTap: canSplit ? () => _showMenu(context) : null,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(
            Icons.splitscreen,
            size: 15,
            color: isSplit
                ? const Color(0xFF2472C8)
                : canSplit
                ? _kFgInactive
                : _kFgInactive.withAlpha(80),
          ),
        ),
      ),
    );
  }
}

// ── Tab chip ──────────────────────────────────────────────────────────────────
class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tab,
    required this.isActive,
    required this.showClose,
    required this.expand,
    required this.onTap,
    required this.onClose,
  });

  final _Tab tab;
  final bool isActive;
  final bool showClose;
  final bool expand;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isActive ? _kBg : Colors.transparent,
          border: Border(
            right: const BorderSide(color: _kDivider),
            bottom: BorderSide(
              color: isActive ? _kBg : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              tab.icon,
              size: 11,
              color: isActive ? _kFgActive : _kFgInactive,
            ),
            const SizedBox(width: 5),
            if (expand)
              Expanded(
                child: Text(
                  tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isActive ? _kFgActive : _kFgInactive,
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              )
            else
              Flexible(
                child: Text(
                  tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isActive ? _kFgActive : _kFgInactive,
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ),
            if (showClose) ...[
              const SizedBox(width: 6),
              _CloseBtn(onTap: onClose, isActive: isActive),
            ],
          ],
        ),
      ),
    );
  }
}

class _CloseBtn extends StatefulWidget {
  const _CloseBtn({required this.onTap, required this.isActive});
  final VoidCallback onTap;
  final bool isActive;

  @override
  State<_CloseBtn> createState() => _CloseBtnState();
}

class _CloseBtnState extends State<_CloseBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFF4A4A4A) : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Icon(
            Icons.close,
            size: 10,
            color: _hover
                ? _kFgActive
                : widget.isActive
                ? _kFgInactive
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

// ── Plus menu ─────────────────────────────────────────────────────────────────
class _PlusMenu extends StatelessWidget {
  const _PlusMenu({
    required this.onNewLocal,
    required this.onRefreshLocalShells,
    required this.onNewSsh,
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
  });

  final ValueChanged<LocalShellOption> onNewLocal;
  final Future<List<LocalShellOption>> Function() onRefreshLocalShells;
  final VoidCallback onNewSsh;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<SshHost> onConnectHost;

  static const _headerStyle = TextStyle(
    color: Color(0xFF6E6E6E),
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );

  PopupMenuItem<String> _sectionHeader(String label) => PopupMenuItem<String>(
    enabled: false,
    height: 28,
    child: Text(label, style: _headerStyle),
  );

  PopupMenuItem<String> _hostItem(SshHost h, String prefix) =>
      PopupMenuItem<String>(
        value: '$prefix:${h.profileKey}',
        height: 36,
        child: Row(
          children: [
            Icon(
              prefix == 'saved'
                  ? Icons.bookmark_outline
                  : Icons.description_outlined,
              size: 13,
              color: _kFgInactive,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    h.alias,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _kFgActive, fontSize: 13),
                  ),
                  Text(
                    h.displayInfo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _kFgInactive, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  PopupMenuItem<String> _shellItem(LocalShellOption shell) => PopupMenuItem(
    value: 'shell:${shell.id}',
    height: 36,
    child: Row(
      children: [
        Icon(
          shell.isWsl ? Icons.laptop_windows : Icons.terminal,
          size: 13,
          color: _kFgInactive,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            shell.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _kFgActive, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Future<void> _showMenu(BuildContext context) async {
    final shells = await onRefreshLocalShells();
    if (!context.mounted) return;

    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
      color: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: _kDivider),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
        minWidth: 220,
      ),
      items: [
        if (shells.isNotEmpty) ...[
          _sectionHeader('Shells'),
          for (final shell in shells) _shellItem(shell),
        ],
        if (savedHosts.isNotEmpty) ...[
          const PopupMenuDivider(height: 1),
          _sectionHeader('Saved'),
          for (final h in savedHosts) _hostItem(h, 'saved'),
        ],
        if (configHosts.isNotEmpty) ...[
          const PopupMenuDivider(height: 1),
          _sectionHeader('~/.ssh/config'),
          for (final h in configHosts) _hostItem(h, 'config'),
        ],
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: 'new',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.add, size: 13, color: _kFgInactive),
              SizedBox(width: 8),
              Text(
                'New SSH…',
                style: TextStyle(color: _kFgActive, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ).then((v) {
      if (v == null) return;
      if (v.startsWith('shell:')) {
        final id = v.substring('shell:'.length);
        for (final shell in shells) {
          if (shell.id == id) {
            onNewLocal(shell);
            return;
          }
        }
        return;
      }
      if (v == 'new') {
        onNewSsh();
        return;
      }
      if (v.startsWith('saved:') || v.startsWith('config:')) {
        final sep = v.indexOf(':');
        final prefix = v.substring(0, sep);
        final key = v.substring(sep + 1);
        final list = prefix == 'saved' ? savedHosts : configHosts;
        for (final h in list) {
          if (h.profileKey == key) {
            onConnectHost(h);
            break;
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => unawaited(_showMenu(context)),
      child: Tooltip(
        message: 'New tab',
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: const Icon(Icons.add, size: 15, color: _kFgInactive),
        ),
      ),
    );
  }
}

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}
