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
import 'services/remote_cwd_parser.dart';
import 'services/remote_home.dart';
import 'services/ssh_connection.dart';
import 'views/settings/settings_sheet.dart';
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
// Flushes once per frame so notifyListeners() and VT parsing fire in one pass.
class _OutputPipe {
  _OutputPipe(this._terminal, {this.transform});

  final Terminal _terminal;
  final List<int> Function(List<int>)? transform;
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
  }
}

// ── Tab model ───────────────────────────────────────────────────────────────
enum _TabKind { local, ssh }

class _Tab {
  _TabKind kind;
  String title;

  Terminal? terminal;
  Pty? pty;
  SSHClient? sshClient;
  SSHSession? sshSession;
  SftpClient? sftp;
  ValueNotifier<String>? remotePath;
  _OutputPipe? pipe;

  _Tab._({
    required this.kind,
    required this.title,
    this.terminal,
    this.pty,
    this.sshClient,
    this.sshSession,
    this.sftp,
    this.remotePath,
  });

  factory _Tab.local(Terminal t, Pty p, String shell) => _Tab._(
        kind: _TabKind.local,
        title: shell,
        terminal: t,
        pty: p,
      );

  factory _Tab.ssh(
    Terminal t,
    SSHClient c,
    SSHSession s,
    String title, {
    SftpClient? sftp,
    ValueNotifier<String>? remotePath,
  }) =>
      _Tab._(
        kind: _TabKind.ssh,
        title: title,
        terminal: t,
        sshClient: c,
        sshSession: s,
        sftp: sftp,
        remotePath: remotePath,
      );

  void dispose() {
    pipe?.dispose();
    remotePath?.dispose();
    pty?.kill();
    sshSession?.close();
    sshClient?.close();
  }

  IconData get icon => switch (kind) {
        _TabKind.local => Icons.terminal,
        _TabKind.ssh => Icons.lock_outline,
      };
}

// ── Home ────────────────────────────────────────────────────────────────────
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
        ..sort((a, b) => a.alias.toLowerCase().compareTo(b.alias.toLowerCase()));
      _configHosts = config
        ..sort((a, b) => a.alias.toLowerCase().compareTo(b.alias.toLowerCase()));
    });
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  // ── Local terminal ────────────────────────────────────────────────────────

  void _newLocalTab() {
    final terminal = Terminal(maxLines: 5000);
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    final env = Map<String, String>.from(Platform.environment)
      ..['TERM'] = 'xterm-256color'
      ..['COLORTERM'] = 'truecolor'
      ..['TERM_PROGRAM'] = 'ssterm';

    final pty = Pty.start(shell, columns: 80, rows: 24, environment: env);

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
  }

  // ── SSH / SFTP ────────────────────────────────────────────────────────────

  Future<void> _showConnectDialog({SshHost? initialHost}) async {
    final result = await showConnectDialog(context, initialHost: initialHost);
    if (result == null || !mounted) return;
    await _rememberHostProfile(result.profile);
    await _openSshTerminal(result);
  }

  /// Persists and refreshes the + menu after a successful manual connect.
  Future<void> _rememberHostProfile(SshHost profile) async {
    try {
      await SavedHostsStore.upsert(profile);
    } catch (_) {
      // Fall through — still update the in-memory menu below.
    }
    await _loadSshHosts();
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
                  Text('Connecting…',
                      style: TextStyle(color: Color(0xFF8E8E8E), fontSize: 13)),
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

    final pipe = _OutputPipe(terminal, transform: (bytes) {
      final parsed = cwdParser.process(bytes);
      if (parsed.cwd != null && parsed.cwd != remotePath.value) {
        remotePath.value = parsed.cwd!;
      }
      return parsed.cleaned;
    });

    terminal.onOutput = (d) => session.stdin.add(utf8.encode(d));
    terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);

    // Bind streams after the first layout so viewWidth matches the widget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      pipe.bind(session.stdout);
      pipe.bind(session.stderr);
    });

    session.done.then((_) {
      if (mounted) terminal.write('\r\n[SSH session closed]\r\n');
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

    setState(() {
      final tab = _Tab.ssh(
        terminal,
        r.client,
        session,
        r.alias,
        sftp: sftp,
        remotePath: remotePath,
      );
      tab.pipe = pipe;
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
  }

  // ── Tab management ────────────────────────────────────────────────────────

  void _closeTab(int i) {
    if (_tabs.length == 1) return;
    _tabs[i].dispose();
    setState(() {
      _tabs.removeAt(i);
      _active = _active.clamp(0, _tabs.length - 1);
    });
  }

  void _openSettings() {
    showTerminalSettingsSheet(
      context,
      settings: _config.terminal,
      onChanged: (next) {
        setState(() => _config.terminal = next);
        _config.save();
      },
    );
  }

  Widget _buildTerminalView(Terminal terminal) {
    final t = _config.terminal;
    return TerminalView(
      terminal,
      theme: t.resolveTheme(),
      textStyle: t.toTerminalStyle(),
      cursorType: t.cursorType,
      cursorBlink: t.cursorBlink,
      cursorBlinkPeriodMs: t.cursorBlinkPeriodMs,
      textScaler: TextScaler.linear(t.textScale),
      padding: const EdgeInsets.all(6),
      autofocus: true,
      hardwareKeyboardOnly: true,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
                onSelect: (i) => setState(() => _active = i),
                onClose: _closeTab,
                onNewLocal: _newLocalTab,
                onNewSsh: () => _showConnectDialog(),
                onSettings: _openSettings,
                savedHosts: _savedHosts,
                configHosts: _configHosts,
                onConnectHost: _connectSavedHost,
              ),
              const Divider(height: 1, thickness: 1, color: _kDivider),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    final tab = _tabs[_active];
    return switch (tab.kind) {
      _TabKind.local => _buildTerminalView(tab.terminal!),
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
            )
          : _buildTerminalView(tab.terminal!),
    };
  }
}

// ── Tab bar ──────────────────────────────────────────────────────────────────
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

  static const _minTabWidth = 100.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      color: _kTabBarBg,
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final canExpand = tabs.isNotEmpty &&
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

                if (canExpand) {
                  return Row(children: chips);
                }
                return SingleChildScrollView(
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
          IconButton(
            tooltip: 'Settings (⌘,)',
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.settings_outlined, size: 18, color: _kFgInactive),
            onPressed: onSettings,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

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
        height: 36,
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
            Icon(tab.icon,
                size: 11,
                color: isActive ? _kFgActive : _kFgInactive),
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

  PopupMenuItem<String> _sectionHeader(String label) {
    return PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(label, style: _headerStyle),
    );
  }

  PopupMenuItem<String> _hostItem(SshHost h, String prefix) {
    return PopupMenuItem<String>(
      value: '$prefix:${h.profileKey}',
      height: 36,
      child: Row(children: [
        Icon(
          prefix == 'saved' ? Icons.bookmark_outline : Icons.description_outlined,
          size: 13,
          color: _kFgInactive,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(h.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kFgActive, fontSize: 13)),
              Text(h.displayInfo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kFgInactive, fontSize: 11)),
            ],
          ),
        ),
      ]),
    );
  }

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
          child: Row(children: [
            Icon(Icons.terminal, size: 13, color: _kFgInactive),
            SizedBox(width: 8),
            Text('系统终端',
                style: TextStyle(color: _kFgActive, fontSize: 13)),
          ]),
        ),
        if (savedHosts.isNotEmpty) ...[
          const PopupMenuDivider(height: 1),
          _sectionHeader('已保存'),
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
          child: Row(children: [
            Icon(Icons.add, size: 13, color: _kFgInactive),
            SizedBox(width: 8),
            Text('新建 SSH…',
                style: TextStyle(color: _kFgActive, fontSize: 13)),
          ]),
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
        message: '新建标签',
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
