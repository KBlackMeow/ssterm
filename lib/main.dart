import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'dialogs/connect_dialog.dart';
import 'models/app_config.dart';
import 'models/saved_hosts_store.dart';
import 'models/ssh_config.dart';
import 'models/ssh_host.dart';
import 'services/host_key_verifier.dart';
import 'services/port_forward_service.dart';
import 'services/remote_cwd_parser.dart';
import 'services/remote_home.dart';
import 'services/session_logger.dart';
import 'services/ssh_connection.dart';
import 'views/settings/settings_sheet.dart' show SettingsPage;
import 'widgets/cmd_picker_button.dart';
import 'widgets/split_view.dart';
import 'widgets/terminal_surface.dart' show TerminalSurface, TerminalContextMenuConfig;
import 'views/ssh_session_view.dart';

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
  bool _pending = false;
  final _subs = <StreamSubscription<List<int>>>[];

  void bind(Stream<List<int>> stream) {
    _subs.add(stream.listen(_onChunk));
  }

  void _onChunk(List<int> chunk) {
    _buf.add(chunk);
    if (!_pending) {
      _pending = true;
      SchedulerBinding.instance.scheduleFrameCallback(_flush);
    }
  }

  void _flush(Duration _) {
    _pending = false;
    var bytes = _buf.takeBytes();
    if (bytes.isEmpty) return;
    sessionLogger?.write(bytes);
    if (transform != null) {
      bytes = Uint8List.fromList(transform!(bytes));
    }
    if (bytes.isNotEmpty) {
      _terminal.write(utf8.decode(bytes, allowMalformed: true));
    }
  }

  void dispose() {
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

  // Primary pane
  Terminal? terminal;
  Pty? pty;
  SSHClient? sshClient;
  SSHClient? jumpClient;
  SSHSession? sshSession;
  SftpClient? sftp;
  ValueNotifier<String>? remotePath;
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

  // Feature 3: in-tab split pane
  Terminal? splitTerminal;
  SSHSession? splitSshSession;
  Pty? splitPty;
  _OutputPipe? splitPipe;
  final splitViewKey = GlobalKey<TerminalViewState>();
  Axis splitAxis = Axis.horizontal;

  final terminalController = TerminalController();
  final splitTerminalController = TerminalController();

  bool get isSplit => splitTerminal != null;

  _Tab._({
    required this.kind,
    required this.title,
    this.terminal,
    this.pty,
    this.sshClient,
    this.jumpClient,
    this.sshSession,
    this.sftp,
    this.remotePath,
    this.sshProfile,
  });

  factory _Tab.local(Terminal t, Pty p, String shell) =>
      _Tab._(kind: _TabKind.local, title: shell, terminal: t, pty: p);

  factory _Tab.ssh(
    Terminal t,
    SSHClient c,
    SSHSession s,
    String title, {
    SSHClient? jumpClient,
    SftpClient? sftp,
    ValueNotifier<String>? remotePath,
    SshHost? profile,
  }) =>
      _Tab._(
        kind: _TabKind.ssh,
        title: title,
        terminal: t,
        sshClient: c,
        jumpClient: jumpClient,
        sshSession: s,
        sftp: sftp,
        remotePath: remotePath,
        sshProfile: profile,
      );

  factory _Tab.settings() =>
      _Tab._(kind: _TabKind.settings, title: 'Settings');

  void clearSplit() {
    splitPipe?.dispose();
    splitSshSession?.close();
    splitPty?.kill();
    splitTerminal = null;
    splitSshSession = null;
    splitPty = null;
    splitPipe = null;
  }

  void dispose() {
    manuallyDisconnected = true;
    keepaliveTimer?.cancel();
    keepaliveTimer = null;
    clearSplit();
    pipe?.dispose();
    remotePath?.dispose();
    forwardService?.stopAll();
    pty?.kill();
    sshSession?.close();
    sshClient?.close();
    jumpClient?.close();
    terminalController.dispose();
    splitTerminalController.dispose();
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
  AppConfig _config = AppConfig();

  @override
  void initState() {
    super.initState();
    _newLocalTab();
    _loadSshHosts();
    AppConfig.load().then((c) {
      if (mounted) setState(() => _config = c);
    });
  }

  Future<void> _loadSshHosts() async {
    final saved = await SavedHostsStore.load();
    final config = await parseSshConfig();
    if (!mounted) return;
    setState(() {
      _savedHosts = saved
        ..sort((a, b) =>
            a.alias.toLowerCase().compareTo(b.alias.toLowerCase()));
      _configHosts = config
        ..sort((a, b) =>
            a.alias.toLowerCase().compareTo(b.alias.toLowerCase()));
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

  void _newLocalTab() {
    final terminal = Terminal(maxLines: 5000);
    final shell = Platform.isWindows
        ? (Platform.environment['COMSPEC'] ?? 'cmd.exe')
        : (Platform.environment['SHELL'] ?? '/bin/zsh');
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final env = Map<String, String>.from(Platform.environment)
      ..['TERM'] = 'xterm-256color'
      ..['COLORTERM'] = 'truecolor'
      ..['TERM_PROGRAM'] = 'ssterm';

    final pty = Pty.start(
      shell,
      arguments: Platform.isWindows ? [] : ['-l'],
      columns: 80,
      rows: 24,
      environment: env,
      workingDirectory: home,
    );
    final pipe = _OutputPipe(terminal)..bind(pty.output);

    pty.exitCode.then((code) {
      if (mounted) terminal.write('\r\n[Process exited with code $code]\r\n');
    });

    terminal.onOutput = (d) => pty.write(utf8.encode(d));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);

    setState(() {
      final tab = _Tab.local(terminal, pty, shell.split('/').last);
      tab.pipe = pipe;
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
    final terminal = Terminal(maxLines: 5000);
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

    terminal.onOutput = (d) => session.stdin.add(utf8.encode(d));
    terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      pipe.bind(session.stdout);
      pipe.bind(session.stderr);
    });

    SftpClient? sftp;
    try {
      sftp = await r.client.sftp();
      remotePath.value = await fetchRemoteHome(r.client);
    } catch (_) {
      remotePath.value = '/';
    }

    if (!mounted) {
      pipe.dispose();
      remotePath.dispose();
      return;
    }

    scheduleRemoteCwdSetup(session);

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

    // Feature 4: auto-reconnect on session close
    session.done.then((_) async {
      tab.keepaliveTimer?.cancel();
      tab.keepaliveTimer = null;
      if (mounted) terminal.write('\r\n[SSH connection closed]\r\n');
      if (!mounted || tab.manuallyDisconnected) return;
      if (r.profile.autoReconnect) {
        terminal.write('[Reconnecting in 3 seconds…]\r\n');
        await Future<void>.delayed(const Duration(seconds: 3));
        if (!mounted || tab.manuallyDisconnected) return;
        _reconnectTab(tab);
      }
    });

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
    final splitTerminal = Terminal(maxLines: 5000);
    SSHSession session;
    try {
      session = await tab.sshClient!.shell(
        pty: const SSHPtyConfig(
          width: 80,
          height: 24,
          type: 'xterm-256color',
        ),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      return;
    }

    final cwdParser = RemoteCwdParser();
    final pipe = _OutputPipe(
      splitTerminal,
      transform: (bytes) => cwdParser.process(bytes).cleaned,
    );

    splitTerminal.onOutput = (d) => session.stdin.add(utf8.encode(d));
    splitTerminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);

    pipe.bind(session.stdout);
    pipe.bind(session.stderr);

    session.done.then((_) {
      if (mounted) setState(() => tab.clearSplit());
    });

    // cd to same directory as primary pane
    final cwd = tab.remotePath?.value ?? '';
    if (cwd.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 800), () {
        final escaped = cwd.replaceAll("'", r"'\''");
        session.stdin.add(utf8.encode("cd '$escaped'\n"));
      });
    }

    scheduleRemoteCwdSetup(session);

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
    final splitTerminal = Terminal(maxLines: 5000);
    final shell = Platform.isWindows
        ? (Platform.environment['COMSPEC'] ?? 'cmd.exe')
        : (Platform.environment['SHELL'] ?? '/bin/zsh');
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final env = Map<String, String>.from(Platform.environment)
      ..['TERM'] = 'xterm-256color'
      ..['COLORTERM'] = 'truecolor'
      ..['TERM_PROGRAM'] = 'ssterm';

    final pty = Pty.start(
      shell,
      arguments: Platform.isWindows ? [] : ['-l'],
      columns: 80,
      rows: 24,
      environment: env,
      workingDirectory: home,
    );
    final pipe = _OutputPipe(splitTerminal)..bind(pty.output);

    splitTerminal.onOutput = (d) => pty.write(utf8.encode(d));
    splitTerminal.onResize = (w, h, pw, ph) => pty.resize(h, w);

    pty.exitCode.then((_) {
      if (mounted) setState(() => tab.clearSplit());
    });

    setState(() {
      tab.splitTerminal = splitTerminal;
      tab.splitPty = pty;
      tab.splitPipe = pipe;
      tab.splitAxis = axis;
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

      tab.terminal!.onOutput = (d) => session.stdin.add(utf8.encode(d));
      tab.terminal!.onResize =
          (w, h, pw, ph) => session.resizeTerminal(w, h);

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

      session.done.then((_) async {
        tab.keepaliveTimer?.cancel();
        if (mounted) tab.terminal?.write('\r\n[SSH connection closed]\r\n');
        if (!mounted || tab.manuallyDisconnected) return;
        if (profile.autoReconnect) {
          tab.terminal?.write('[Reconnecting in 3 seconds…]\r\n');
          await Future<void>.delayed(const Duration(seconds: 3));
          if (!mounted || tab.manuallyDisconnected) return;
          _reconnectTab(tab);
        }
      });

      scheduleRemoteCwdSetup(session);
      tab.terminal?.write('[Reconnected]\r\n');
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        tab.terminal?.write('[Reconnect failed: $e]\r\n');
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
    if (_tabs.length == 1) return;
    _tabs[i].dispose();
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
    _tabs[_active].terminal?.onOutput?.call(cmd);
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
      _tabs.isNotEmpty &&
      _active < _tabs.length &&
      _tabs[_active].isSplit;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.comma):
            const _OpenSettingsIntent(),
      },
      child: Actions(
        actions: {
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
            onInvoke: (_) {
              _openSettings();
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
                onNewSsh: () => _showConnectDialog(),
                onSettings: _openSettings,
                savedHosts: _savedHosts,
                configHosts: _configHosts,
                onConnectHost: _connectSavedHost,
                onInsertCommand:
                    _tabs.isNotEmpty && _tabs[_active].terminal != null
                        ? _insertCommand
                        : null,
                hasSftp: _tabs.isNotEmpty &&
                    _active < _tabs.length &&
                    _tabs[_active].sftp != null,
                sftpVisible: _tabs.isNotEmpty &&
                    _active < _tabs.length &&
                    _tabs[_active].sftpPanelVisible,
                onToggleSftp: () {
                  if (_tabs.isNotEmpty && _active < _tabs.length) {
                    setState(() => _tabs[_active].sftpPanelVisible =
                        !_tabs[_active].sftpPanelVisible);
                  }
                },
                canSplit: _activeTabCanSplit,
                isSplit: _activeTabIsSplit,
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

  Widget _buildPrimaryContent(_Tab tab, {TerminalContextMenuConfig? contextMenu}) {
    return switch (tab.kind) {
      _TabKind.local =>
        _buildTerminalView(tab.terminal!, tab.terminalViewKey, contextMenu: contextMenu),
      _TabKind.ssh => tab.sftp != null
          ? SshSessionView(
              terminal: tab.terminal!,
              sftp: tab.sftp!,
              host: tab.title,
              remotePath: tab.remotePath!,
              panelPosition: _config.sftpPanelPosition,
              onPanelPositionChanged: (pos) {
                setState(() => _config.sftpPanelPosition = pos);
                _config.save();
              },
              terminalSettings: _config.terminal,
              terminalViewKey: tab.terminalViewKey,
              sftpVisible: tab.sftpPanelVisible,
              onToggleSftp: () =>
                  setState(() => tab.sftpPanelVisible = !tab.sftpPanelVisible),
              contextMenu: contextMenu,
            )
          : _buildTerminalView(tab.terminal!, tab.terminalViewKey, contextMenu: contextMenu),
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

    final primary = _buildPrimaryContent(tab, contextMenu: primaryMenu);

    if (!tab.isSplit) return primary;

    final splitMenu = TerminalContextMenuConfig(
      controller: tab.splitTerminalController,
      canSplit: canSplit,
      isSplit: true,
      onSplitHorizontal: () => _splitCurrentTab(Axis.horizontal),
      onSplitVertical: () => _splitCurrentTab(Axis.vertical),
      onCloseSplit: _closeSplitCurrentTab,
    );

    final secondary = _buildTerminalView(
      tab.splitTerminal!,
      tab.splitViewKey,
      contextMenu: splitMenu,
    );

    return SplitView(
      primary: primary,
      secondary: secondary,
      axis: tab.splitAxis,
    );
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
    required this.onNewSsh,
    required this.onSettings,
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
    required this.hasSftp,
    required this.sftpVisible,
    required this.onToggleSftp,
    required this.canSplit,
    required this.isSplit,
    required this.onSplitHorizontal,
    required this.onSplitVertical,
    required this.onCloseSplit,
    this.onInsertCommand,
  });

  final List<_Tab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNewLocal;
  final VoidCallback onNewSsh;
  final VoidCallback onSettings;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<SshHost> onConnectHost;
  final ValueChanged<String>? onInsertCommand;
  final bool hasSftp;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final bool canSplit;
  final bool isSplit;
  final VoidCallback onSplitHorizontal;
  final VoidCallback onSplitVertical;
  final VoidCallback onCloseSplit;

  static const _minTabWidth = 100.0;

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
                final canExpand =
                    tabs.isNotEmpty &&
                    tabs.length * _minTabWidth <= constraints.maxWidth;

                final chips = [
                  for (var i = 0; i < tabs.length; i++)
                    canExpand
                        ? Expanded(
                            child: _TabChip(
                              tab: tabs[i],
                              isActive: i == active,
                              showClose: tabs.length > 1,
                              expand: true,
                              onTap: () => onSelect(i),
                              onClose: () => onClose(i),
                            ),
                          )
                        : SizedBox(
                            width: _minTabWidth,
                            child: _TabChip(
                              tab: tabs[i],
                              isActive: i == active,
                              showClose: tabs.length > 1,
                              expand: false,
                              onTap: () => onSelect(i),
                              onClose: () => onClose(i),
                            ),
                          ),
                ];

                return canExpand
                    ? Row(children: chips)
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: chips),
                      );
              },
            ),
          ),
          _PlusMenu(
            onLocal: onNewLocal,
            onNewSsh: onNewSsh,
            savedHosts: savedHosts,
            configHosts: configHosts,
            onConnectHost: onConnectHost,
          ),
          CmdPickerButton(onInsert: onInsertCommand),
          if (hasSftp)
            _SftpButton(
              sftpVisible: sftpVisible,
              onToggle: onToggleSftp,
            ),
          _SplitButton(
            canSplit: canSplit,
            isSplit: isSplit,
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
            color: sftpVisible
                ? const Color(0xFF2472C8)
                : _kFgInactive,
          ),
        ),
      ),
    );
  }
}

// ── Split button ──────────────────────────────────────────────────────────────
class _SplitButton extends StatelessWidget {
  const _SplitButton({
    required this.canSplit,
    required this.isSplit,
    required this.onSplitHorizontal,
    required this.onSplitVertical,
    required this.onCloseSplit,
  });

  final bool canSplit;
  final bool isSplit;
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
              const Icon(Icons.splitscreen, size: 13, color: _kFgInactive),
              const SizedBox(width: 8),
              Text(
                'Split horizontal',
                style: TextStyle(
                  color: isSplit ? const Color(0xFF2472C8) : _kFgActive,
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
              const Icon(Icons.vertical_split, size: 13, color: _kFgInactive),
              const SizedBox(width: 8),
              const Text(
                'Split vertical',
                style: TextStyle(color: _kFgActive, fontSize: 13),
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
                    fontWeight:
                        isActive ? FontWeight.w500 : FontWeight.normal,
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
                    fontWeight:
                        isActive ? FontWeight.w500 : FontWeight.normal,
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
    required this.onLocal,
    required this.onNewSsh,
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
  });

  final VoidCallback onLocal;
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

  PopupMenuItem<String> _sectionHeader(String label) =>
      PopupMenuItem<String>(
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
                    style:
                        const TextStyle(color: _kFgInactive, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

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
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
        minWidth: 220,
      ),
      items: [
        const PopupMenuItem(
          value: 'local',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.terminal, size: 13, color: _kFgInactive),
              SizedBox(width: 8),
              Text(
                'Local terminal',
                style: TextStyle(color: _kFgActive, fontSize: 13),
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
      ],
    ).then((v) {
      if (v == null) return;
      if (v == 'local') {
        onLocal();
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
