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
import 'services/wallpaper_storage.dart';
import 'utils/fd_limit.dart';
import 'views/settings/settings_sheet.dart' show SettingsPage;
import 'widgets/cmd_picker_button.dart';
import 'widgets/frosted_glass.dart';
import 'widgets/split_view.dart';
import 'widgets/terminal_surface.dart'
    show TerminalSurface, TerminalContextMenuConfig;
import 'models/transfer_task.dart';
import 'views/ssh_session_view.dart';
import 'widgets/transfer_panel.dart';
import 'widgets/wallpaper_background.dart';

void main() {
  // Must run before the first Pty.start: spawned shells inherit RLIMIT_NOFILE
  // from this process, and macOS's default 256 is too low for plugin-heavy
  // zsh setups.
  raiseFileDescriptorLimit();
  runApp(const SsTermApp());
}

class SsTermApp extends StatelessWidget {
  const SsTermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSTerm',
      debugShowCheckedModeBanner: false,
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: const TerminalHome(),
    );
  }
}

// Chrome palette — foreground; backgrounds come from [TerminalSettings].
const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);
const _kTabRadius = 6.0;

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

  // Pane 0 (single-pane slot; left/top when split)
  Terminal? terminal;
  Pty? pty;
  SSHClient? sshClient;
  SSHClient? jumpClient;
  SSHSession? sshSession;
  SftpClient? sftp;
  ValueNotifier<String>? remotePath;
  /// Last cwd reported by pane 0 / pane 1 (OSC 7 from each shell).
  String? remoteCwdPane0;
  String? remoteCwdPane1;
  int activeSshPane = 0;
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

  // Pane 1 (right/bottom when split) — peer of pane 0, not a "secondary" role
  Terminal? splitTerminal;
  SSHSession? splitSshSession;
  Pty? splitPty;
  _OutputPipe? splitPipe;
  final splitViewKey = GlobalKey<TerminalViewState>();
  Axis splitAxis = Axis.horizontal;

  final terminalController = TerminalController();
  final splitTerminalController = TerminalController();

  /// Pane 0 session ended (single pane, or before collapse).
  bool primarySessionEnded = false;

  /// Pane 1 session ended.
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

  /// Ends pane 1 and returns to a single pane (pane 0). Used when pane 1 exits
  /// or on reconnect — not exposed as a manual "close split" action.
  void clearSplit() {
    splitPipe?.dispose();
    splitSshSession?.close();
    splitPty?.kill();
    splitTerminal = null;
    splitSshSession = null;
    splitPty = null;
    splitPipe = null;
    splitSessionEnded = false;
    remoteCwdPane1 = null;
    if (activeSshPane == 1) activeSshPane = 0;
    syncRemotePathToActivePane();
  }

  void syncRemotePathToActivePane() {
    if (remotePath == null) return;
    final cwd = activeSshPane == 1 && isSplit
        ? (remoteCwdPane1 ?? remoteCwdPane0)
        : remoteCwdPane0;
    if (cwd != null && cwd.isNotEmpty) {
      remotePath!.value = cwd;
    }
  }

  /// Pane 0 exited while split — move pane 1 into the single-pane slot.
  void retainPane1() {
    if (splitTerminal == null) return;

    remoteCwdPane0 = remoteCwdPane1 ?? remoteCwdPane0;
    remoteCwdPane1 = null;
    activeSshPane = 0;
    syncRemotePathToActivePane();

    pipe?.dispose();
    pipe = null;
    pty?.kill();
    pty = null;
    sshSession?.close();
    sshSession = null;

    terminal = splitTerminal;
    splitTerminal = null;
    pty = splitPty;
    splitPty = null;
    sshSession = splitSshSession;
    splitSshSession = null;
    pipe = splitPipe;
    splitPipe = null;
    primarySessionEnded = false;
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
    _loadSshHosts();
    AppConfig.load().then((c) {
      if (!mounted) return;
      setState(() {
        _config = c;
        // Prefer the persisted list (includes WSL distros on Windows) over the
        // boot-time sync discovery. Falls back to the sync result when the
        // config has nothing yet (first launch).
        if (c.cachedShells.isNotEmpty) _localShells = c.cachedShells;
      });
      // Background diff: only setState + save when the discovered list
      // actually differs from what we just restored. This keeps subsequent
      // `+` clicks free of any discovery cost and avoids gratuitous rebuilds
      // of the chrome (which would otherwise thrash the paragraph caches of
      // every open terminal).
      unawaited(_refreshLocalShellsIfChanged());
    });
  }

  /// Re-runs discovery in the background. Only mutates state when the result
  /// differs from the current [_localShells]; the persisted cache in
  /// [_config.cachedShells] is updated in the same step.
  Future<void> _refreshLocalShellsIfChanged() async {
    final shells = await LocalShellDiscovery.discover(refresh: true);
    if (!mounted) return;
    if (LocalShellDiscovery.listsStructurallyEqual(shells, _localShells)) {
      return;
    }
    setState(() => _localShells = shells);
    _config.cachedShells = shells;
    unawaited(_config.save());
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

  List<int> Function(List<int>) _sshOutputTransform(
    _Tab tab,
    int pane,
    RemoteCwdParser parser,
  ) {
    return (bytes) {
      final parsed = parser.process(bytes);
      if (parsed.cwd != null) {
        _noteRemoteCwd(tab, pane, parsed.cwd!);
      }
      return parsed.cleaned;
    };
  }

  void _noteRemoteCwd(_Tab tab, int pane, String cwd) {
    // After retainPane1 the surviving shell still reports as pane 1 in its pipe
    // transform; map to pane 0 storage while no longer split.
    final storagePane = !tab.isSplit && pane == 1 ? 0 : pane;
    if (storagePane == 0) {
      tab.remoteCwdPane0 = cwd;
    } else {
      tab.remoteCwdPane1 = cwd;
    }
    if (!tab.isSplit || tab.activeSshPane == storagePane) {
      tab.remotePath?.value = cwd;
    }
  }

  /// Point SFTP at the cwd for the pane the user clicked (see [_buildTerminalView]).
  void _activateSshPaneForSftp(_Tab tab, int pane) {
    if (tab.kind != _TabKind.ssh || tab.sftp == null) return;
    tab.activeSshPane = pane;
    tab.syncRemotePathToActivePane();
  }

  /// Which pane owns [terminal] right now (0 or 1). Resolves after split collapse.
  int? _paneIndexOf(_Tab tab, Terminal terminal) {
    if (tab.terminal == terminal) return 0;
    if (tab.splitTerminal == terminal) return 1;
    return null;
  }

  bool _paneSessionEnded(_Tab tab, int pane) =>
      pane == 1 ? tab.splitSessionEnded : tab.primarySessionEnded;

  void _setPaneSessionEnded(_Tab tab, int pane, bool ended) {
    if (pane == 1) {
      tab.splitSessionEnded = ended;
    } else {
      tab.primarySessionEnded = ended;
    }
  }

  void _bindTerminalInput(
    Terminal terminal,
    _Tab tab, {
    required void Function(String data) forward,
  }) {
    terminal.onOutput = (data) {
      final pane = _paneIndexOf(tab, terminal);
      if (pane == null) return;
      if (_paneSessionEnded(tab, pane)) {
        if (_isRestartKey(data)) {
          unawaited(_restartSession(tab, terminal: terminal));
        }
        return;
      }
      forward(data);
    };
  }

  Future<void> _restartSession(_Tab tab, {required Terminal terminal}) async {
    final pane = _paneIndexOf(tab, terminal);
    if (pane == null || !_paneSessionEnded(tab, pane) || !mounted) return;

    _setPaneSessionEnded(tab, pane, false);

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
        pane: pane,
      );
    } else if (tab.kind == _TabKind.ssh) {
      await _restartSshShell(tab, terminal: terminal, pane: pane);
    }
  }

  void _handlePaneExited(
    _Tab tab, {
    required Terminal terminal,
    required int pane,
    int? exitCode,
    bool showExitMessage = true,
    bool ssh = false,
  }) {
    if (!mounted) return;

    if (pane == 1) {
      tab.splitPty = null;
      tab.splitPipe?.dispose();
      tab.splitPipe = null;
      tab.splitSshSession?.close();
      tab.splitSshSession = null;
    } else {
      tab.pty = null;
      tab.pipe?.dispose();
      tab.pipe = null;
      tab.sshSession?.close();
      tab.sshSession = null;
    }

    if (showExitMessage && exitCode != null && !ssh) {
      terminal.write('\r\n[Process exited with code $exitCode]\r\n');
    }
    if (ssh) {
      terminal.write('\r\n[SSH connection closed]\r\n');
    }

    final paneNow = _paneIndexOf(tab, terminal) ?? pane;
    if (tab.isSplit) {
      _collapseSplitAfterExit(tab, paneIndex: paneNow);
      return;
    }

    terminal.write(_kRestartPrompt);
    _setPaneSessionEnded(tab, paneNow, true);
  }

  void _spawnLocalPty({
    required _Tab tab,
    required Terminal terminal,
    required LocalShellOption shell,
    required int columns,
    required int rows,
    String? workingDirectory,
    required int pane,
    bool showExitMessage = true,
  }) {
    if (columns < 1 || rows < 1) return;

    final isSplit = pane == 1;
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
      forward: (d) => pty.write(utf8.encode(d)),
    );

    pty.exitCode.then((code) {
      _handlePaneExited(
        tab,
        terminal: terminal,
        pane: pane,
        exitCode: code,
        showExitMessage: showExitMessage,
      );
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
      final pane = _paneIndexOf(tab, terminal) ?? (isSplit ? 1 : 0);
      final activePty = pane == 1 ? tab.splitPty : tab.pty;
      if (activePty == null && !_paneSessionEnded(tab, pane)) {
        _spawnLocalPty(
          tab: tab,
          terminal: terminal,
          shell: shell,
          columns: w,
          rows: h,
          workingDirectory: workingDirectory,
          pane: pane,
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
    SshHost? profile,
  }) async {
    final pane = _paneIndexOf(tab, terminal) ?? 0;

    if (pane == 0) {
      tab.keepaliveTimer?.cancel();
      tab.keepaliveTimer = null;
    }
    if (!mounted || tab.manuallyDisconnected) return;

    final prof = profile ?? tab.sshProfile;

    if (pane == 0 && tab.isSplit) {
      tab.sshSession?.close();
      tab.sshSession = null;
      tab.pipe?.dispose();
      tab.pipe = null;
      _handlePaneExited(tab, terminal: terminal, pane: 0, ssh: true);
      return;
    }

    if (pane == 0 && prof != null && prof.autoReconnect) {
      terminal.write('\r\n[SSH connection closed]\r\n');
      terminal.write('[Reconnecting in 3 seconds…]\r\n');
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted || tab.manuallyDisconnected) return;
      await _reconnectTab(tab);
      return;
    }

    if (tab.isSplit && pane == 1) {
      tab.splitSshSession?.close();
      tab.splitSshSession = null;
      tab.splitPipe?.dispose();
      tab.splitPipe = null;
      _handlePaneExited(tab, terminal: terminal, pane: 1, ssh: true);
      return;
    }

    tab.sshSession?.close();
    tab.sshSession = null;
    tab.pipe?.dispose();
    tab.pipe = null;
    _handlePaneExited(tab, terminal: terminal, pane: pane, ssh: true);
  }

  Future<void> _restartSshShell(
    _Tab tab, {
    required Terminal terminal,
    required int pane,
  }) async {
    final client = tab.sshClient;
    if (client == null) {
      if (pane == 0 && tab.sshProfile != null) {
        await _reconnectTab(tab);
      } else {
        terminal.write('[Not connected]\r\n$_kRestartPrompt');
        _setPaneSessionEnded(tab, pane, true);
      }
      return;
    }

    try {
      final session = await client
          .execute(
            interactiveShellWrapperCommand(),
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
        transform: _sshOutputTransform(tab, pane, cwdParser),
      );

      _bindTerminalInput(
        terminal,
        tab,
        forward: (d) => session.stdin.add(utf8.encode(d)),
      );
      terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);

      pipe.bind(session.stdout);
      pipe.bind(session.stderr);

      if (pane == 1) {
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

      session.done.then((_) => _handleSshSessionDone(tab, terminal, profile: tab.sshProfile));
    } catch (e) {
      if (!mounted) return;
      terminal.write('[Reconnect failed: $e]\r\n$_kRestartPrompt');
      final paneNow = _paneIndexOf(tab, terminal) ?? pane;
      if (tab.isSplit) {
        _collapseSplitAfterExit(tab, paneIndex: paneNow);
      } else {
        _setPaneSessionEnded(tab, paneNow, true);
      }
    }
  }

  /// [paneIndex] 0 = pane 0 (terminal), 1 = pane 1 (splitTerminal).
  void _collapseSplitAfterExit(_Tab tab, {required int paneIndex}) {
    if (!tab.isSplit) {
      _setPaneSessionEnded(tab, 0, true);
      return;
    }
    if (paneIndex == 1) {
      setState(() => tab.clearSplit());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        tab.terminalViewKey.currentState?.syncAfterShown();
      });
      return;
    }
    setState(() => tab.retainPane1());
    _rewirePane0AfterCollapse(tab);
  }

  void _rewirePane0AfterCollapse(_Tab tab) {
    final terminal = tab.terminal;
    if (terminal == null) return;

    if (tab.kind == _TabKind.local && tab.pty != null) {
      _bindTerminalInput(
        terminal,
        tab,
        forward: (d) => tab.pty!.write(utf8.encode(d)),
      );
      terminal.onResize = (w, h, pw, ph) {
        if (w >= 1 && h >= 1) tab.pty!.resize(h, w);
      };
    } else if (tab.sshSession != null) {
      _bindTerminalInput(
        terminal,
        tab,
        forward: (d) => tab.sshSession!.stdin.add(utf8.encode(d)),
      );
      terminal.onResize = (w, h, pw, ph) =>
          tab.sshSession!.resizeTerminal(w, h);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      tab.terminalViewKey.currentState?.syncAfterShown();
    });
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
      forward: (d) => session.stdin.add(utf8.encode(d)),
    );
    terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);
    session.done.then(
      (_) => _handleSshSessionDone(tab, terminal, profile: profile),
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
    ENV=/dev/fd/3 exec "$shell" --posix --noprofile -i 3<<'RCEOF'
set +o posix
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
RCEOF
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

    SessionLogger? logger;
    if (r.profile.sessionLog) {
      try {
        logger = await SessionLogger.create(r.alias);
      } catch (_) {}
    }

    // Tab must exist before the output pipe can run — SSH may send data immediately.
    final tab = _Tab.ssh(
      terminal,
      r.client,
      session,
      r.alias,
      jumpClient: r.jumpClient,
      remotePath: remotePath,
      profile: r.profile,
    );
    tab.activeSshPane = 0;

    final cwdParser = RemoteCwdParser();
    final pipe = _OutputPipe(
      terminal,
      sessionLogger: logger,
      transform: _sshOutputTransform(tab, 0, cwdParser),
    );
    tab.pipe = pipe;

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
      tab.dispose();
      return;
    }

    tab.sftp = sftp;
    tab.transferManager = transferManager;
    tab.remoteCwdPane0 = remotePath.value;

    _wireSshSession(
      tab,
      session,
      terminal,
      pipe,
      isSplit: false,
      profile: r.profile,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      pipe.bind(session.stdout);
      pipe.bind(session.stderr);
    });

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
      if (tab.splitAxis != axis) {
        setState(() => tab.splitAxis = axis);
      }
      return;
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
          .execute(
            interactiveShellWrapperCommand(),
            pty: SSHPtyConfig(
              width: splitTerminal.viewWidth,
              height: splitTerminal.viewHeight,
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
      transform: _sshOutputTransform(tab, 1, cwdParser),
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
      tab.remoteCwdPane1 = tab.remoteCwdPane0;
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
        transform: _sshOutputTransform(tab, 0, cwdParser),
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
    required _Tab tab,
    int sshPane = 0,
    TerminalContextMenuConfig? contextMenu,
  }) {
    Widget surface = TerminalSurface(
      key: ValueKey(terminal),
      terminal: terminal,
      settings: _config.terminal,
      viewKey: viewKey,
      contextMenu: contextMenu,
      frostedGlass: _config.sftpFrostedGlass,
      includeWallpaper: false,
      autofocus: sshPane == 0,
    );

    if (tab.kind == _TabKind.ssh && tab.sftp != null) {
      surface = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _activateSshPaneForSftp(tab, sshPane),
        child: surface,
      );
    }

    return surface;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  bool get _activeTabCanSplit {
    if (_tabs.isEmpty || _active >= _tabs.length) return false;
    final kind = _tabs[_active].kind;
    return kind == _TabKind.local || kind == _TabKind.ssh;
  }

  bool get _activeTabIsSplit =>
      _tabs.isNotEmpty && _active < _tabs.length && _tabs[_active].isSplit;

  Widget _buildChrome() {
    final ts = _config.terminal;
    final hasWallpaper = ts.hasWallpaper;
    final wallpaperFile =
        hasWallpaper ? WallpaperStorage.resolveFile(ts.wallpaperId) : null;

    Widget chrome = Column(
      children: [
        _TabBar(
          tabs: _tabs,
          active: _active,
          backgroundColor: ts.chromeBackground,
          tabSelectedColor: ts.chromeTabSelected,
          tabUnselectedColor: ts.chromeTabUnselected,
          onSelect: _selectTab,
          onClose: _closeTab,
          onNewLocal: _newLocalTab,
          localShells: _localShells,
          onRefreshLocalShells: _refreshLocalShellsIfChanged,
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
          frostedGlass: _config.sftpFrostedGlass,
          onFrostedGlassChanged: (v) {
            setState(() => _config.sftpFrostedGlass = v);
            _config.save();
          },
        ),
        Expanded(child: _buildBody()),
      ],
    );

    if (wallpaperFile != null) {
      chrome = Stack(
        fit: StackFit.expand,
        children: [
          WallpaperBackground(
            file: wallpaperFile,
            opacity: ts.wallpaperOpacity,
            blur: ts.wallpaperBlur,
          ),
          chrome,
        ],
      );
    }

    return Scaffold(
      backgroundColor:
          wallpaperFile != null ? Colors.transparent : ts.chromeBackground,
      body: chrome,
    );
  }

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
        child: _buildChrome(),
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
        tab: tab,
        sshPane: 0,
        contextMenu: contextMenu,
      ),
      _TabKind.settings => SettingsPage(
        settings: _config.terminal,
        onChanged: (next) {
          setState(() => _config.terminal = next);
          _config.save();
          _syncAllTerminals();
        },
        sftpFrostedGlass: _config.sftpFrostedGlass,
        onSftpFrostedGlassChanged: (v) {
          setState(() => _config.sftpFrostedGlass = v);
          _config.save();
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
    );

    Widget body = _buildPrimaryContent(tab, contextMenu: primaryMenu);

    if (tab.isSplit) {
      final splitMenu = TerminalContextMenuConfig(
        controller: tab.splitTerminalController,
        canSplit: canSplit,
        isSplit: true,
        onSplitHorizontal: () => _splitCurrentTab(Axis.horizontal),
        onSplitVertical: () => _splitCurrentTab(Axis.vertical),
      );
      body = SplitView(
        primary: body,
        secondary: _buildTerminalView(
          tab.splitTerminal!,
          tab.splitViewKey,
          tab: tab,
          sshPane: 1,
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
        frostedGlass: _config.sftpFrostedGlass,
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
    required this.backgroundColor,
    required this.tabSelectedColor,
    required this.tabUnselectedColor,
    required this.onSelect,
    required this.onClose,
    required this.onNewLocal,
    required this.localShells,
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
    required this.frostedGlass,
    this.onFrostedGlassChanged,
    this.onInsertCommand,
  });

  final List<_Tab> tabs;
  final int active;
  final Color backgroundColor;
  final Color tabSelectedColor;
  final Color tabUnselectedColor;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final ValueChanged<LocalShellOption> onNewLocal;
  final List<LocalShellOption> localShells;
  final Future<void> Function() onRefreshLocalShells;
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
  final bool frostedGlass;
  final ValueChanged<bool>? onFrostedGlassChanged;

  static const _preferredTabWidth = 160.0;
  static const _minTabWidth = 80.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (tabs.isEmpty) return const SizedBox.shrink();

                const tabGap = 4.0;
                final slotWidth =
                    (constraints.maxWidth - tabGap * (tabs.length - 1)) /
                    tabs.length;
                final tabWidth = slotWidth.clamp(_minTabWidth, _preferredTabWidth);
                final needsScroll =
                    tabWidth <= _minTabWidth &&
                    tabs.length * (_minTabWidth + tabGap) > constraints.maxWidth;

                final chips = [
                  for (var i = 0; i < tabs.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        right: i < tabs.length - 1 ? tabGap : 0,
                      ),
                      child: SizedBox(
                        width: needsScroll ? _minTabWidth : tabWidth,
                        child: _TabChip(
                          tab: tabs[i],
                          isActive: i == active,
                          tabSelectedColor: tabSelectedColor,
                          tabUnselectedColor: tabUnselectedColor,
                          showClose: true,
                          expand: true,
                          onTap: () => onSelect(i),
                          onClose: () => onClose(i),
                        ),
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
            shells: localShells,
            onRefreshLocalShells: onRefreshLocalShells,
            onNewSsh: onNewSsh,
            savedHosts: savedHosts,
            configHosts: configHosts,
            onConnectHost: onConnectHost,
            frostedGlass: frostedGlass,
            onFrostedGlassChanged: onFrostedGlassChanged,
          ),
          CmdPickerButton(
            onInsert: onInsertCommand,
            frostedGlass: frostedGlass,
          ),
          if (hasSftp) ...[
            _SftpButton(sftpVisible: sftpVisible, onToggle: onToggleSftp),
            if (transferManager != null)
              _TransferButton(
                manager: transferManager!,
                frostedGlass: frostedGlass,
              ),
          ],
          _SplitButton(
            canSplit: canSplit,
            isSplit: isSplit,
            splitAxis: splitAxis,
            onSplitHorizontal: onSplitHorizontal,
            onSplitVertical: onSplitVertical,
            frostedGlass: frostedGlass,
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
  const _TransferButton({
    required this.manager,
    required this.frostedGlass,
  });

  final TransferManager manager;
  final bool frostedGlass;

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showTransferMenu(
      context: context,
      frostedGlass: frostedGlass,
      manager: manager,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
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
    required this.frostedGlass,
  });

  final bool canSplit;
  final bool isSplit;
  final Axis? splitAxis;
  final VoidCallback onSplitHorizontal;
  final VoidCallback onSplitVertical;
  final bool frostedGlass;

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showFrostedMenu<String>(
      context: context,
      frostedGlass: frostedGlass,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
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
      ],
    ).then((v) {
      if (v == 'h') onSplitHorizontal();
      if (v == 'v') onSplitVertical();
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
class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.tab,
    required this.isActive,
    required this.tabSelectedColor,
    required this.tabUnselectedColor,
    required this.showClose,
    required this.expand,
    required this.onTap,
    required this.onClose,
  });

  final _Tab tab;
  final bool isActive;
  final Color tabSelectedColor;
  final Color tabUnselectedColor;
  final bool showClose;
  final bool expand;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isActive;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isActive
                ? widget.tabSelectedColor
                : widget.tabUnselectedColor,
            borderRadius: BorderRadius.circular(_kTabRadius),
          ),
          child: Row(
            children: [
              Icon(
                widget.tab.icon,
                size: 12,
                color: isActive ? _kFgActive : _kFgInactive,
              ),
              const SizedBox(width: 6),
              if (widget.expand)
                Expanded(
                  child: Text(
                    widget.tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? _kFgActive : _kFgInactive,
                      fontSize: 12,
                      fontWeight:
                          isActive ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                )
              else
                Flexible(
                  child: Text(
                    widget.tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? _kFgActive : _kFgInactive,
                      fontSize: 12,
                      fontWeight:
                          isActive ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                ),
              if (widget.showClose) ...[
                const SizedBox(width: 4),
                _CloseBtn(
                  onTap: widget.onClose,
                  visible: isActive || _hover,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseBtn extends StatefulWidget {
  const _CloseBtn({required this.onTap, required this.visible});

  final VoidCallback onTap;
  final bool visible;

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
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFF4A4A4A) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.close,
            size: 11,
            color: widget.visible
                ? (_hover ? _kFgActive : _kFgInactive)
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
    required this.shells,
    required this.onRefreshLocalShells,
    required this.onNewSsh,
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
    required this.frostedGlass,
    this.onFrostedGlassChanged,
  });

  static const _frostedToggleValue = '__frosted_glass__';
  static const _refreshShellsValue = '__refresh_shells__';

  final ValueChanged<LocalShellOption> onNewLocal;
  /// Cached list rendered synchronously. Updated by the host via
  /// [onRefreshLocalShells] (background diff; no per-open work).
  final List<LocalShellOption> shells;
  final Future<void> Function() onRefreshLocalShells;
  final VoidCallback onNewSsh;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<SshHost> onConnectHost;
  final bool frostedGlass;
  final ValueChanged<bool>? onFrostedGlassChanged;

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

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showFrostedMenu<String>(
      context: context,
      frostedGlass: frostedGlass,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
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
        PopupMenuItem<String>(
          value: _refreshShellsValue,
          height: 32,
          child: Row(
            children: const [
              Icon(Icons.refresh, size: 13, color: _kFgInactive),
              SizedBox(width: 8),
              Text(
                'Refresh shells',
                style: TextStyle(color: _kFgInactive, fontSize: 12),
              ),
            ],
          ),
        ),
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
        if (onFrostedGlassChanged != null) ...[
          const PopupMenuDivider(height: 1),
          PopupMenuItem(
            value: _frostedToggleValue,
            height: 36,
            child: Row(
              children: [
                const Icon(Icons.blur_on, size: 13, color: _kFgInactive),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Frosted glass',
                    style: TextStyle(color: _kFgActive, fontSize: 13),
                  ),
                ),
                if (frostedGlass)
                  const Icon(
                    Icons.check,
                    size: 14,
                    color: Color(0xFF2472C8),
                  ),
              ],
            ),
          ),
        ],
      ],
    ).then((v) {
      if (v == null) return;
      if (v == _frostedToggleValue) {
        onFrostedGlassChanged?.call(!frostedGlass);
        return;
      }
      if (v == _refreshShellsValue) {
        unawaited(onRefreshLocalShells());
        return;
      }
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
      onTap: () => _showMenu(context),
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
