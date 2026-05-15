import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'dialogs/connect_dialog.dart';
import 'views/sftp_view.dart';

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

// ── iTerm2 color palette ────────────────────────────────────────────────────
const _kTheme = TerminalTheme(
  cursor: Color(0xFFD4D4D4),
  selection: Color(0xFF4E6F91),
  foreground: Color(0xFFC7C7C7),
  background: Color(0xFF1C1C1C),
  black: Color(0xFF000000),
  white: Color(0xFFC7C7C7),
  red: Color(0xFFC91B00),
  green: Color(0xFF00C200),
  yellow: Color(0xFFC7C400),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFC930C7),
  cyan: Color(0xFF00C5C7),
  brightBlack: Color(0xFF686868),
  brightWhite: Color(0xFFFFFFFF),
  brightRed: Color(0xFFFF6E67),
  brightGreen: Color(0xFF5FFA68),
  brightYellow: Color(0xFFFFFC67),
  brightBlue: Color(0xFF6871FF),
  brightMagenta: Color(0xFFFF77FF),
  brightCyan: Color(0xFF60FDFF),
  searchHitBackground: Color(0xFFFF9F00),
  searchHitBackgroundCurrent: Color(0xFFFF6600),
  searchHitForeground: Color(0xFFFFFFFF),
);

const _kBg = Color(0xFF1C1C1C);
const _kTabBarBg = Color(0xFF2B2B2B);
const _kDivider = Color(0xFF3A3A3A);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);

// ── I/O → Terminal bridge ────────────────────────────────────────────────────
// Flushes once per frame so notifyListeners() and VT parsing fire in one pass.
class _OutputPipe {
  _OutputPipe(this._terminal);

  final Terminal _terminal;
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
    final bytes = _buf.takeBytes();
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
enum _TabKind { local, ssh, sftp }

class _Tab {
  _TabKind kind;
  String title;

  Terminal? terminal;
  Pty? pty;
  SSHClient? sshClient;
  SSHSession? sshSession;
  SftpClient? sftp;
  String? sftpHost;
  _OutputPipe? pipe;

  _Tab._({
    required this.kind,
    required this.title,
    this.terminal,
    this.pty,
    this.sshClient,
    this.sshSession,
    this.sftp,
    this.sftpHost,
  });

  factory _Tab.local(Terminal t, Pty p, String shell) => _Tab._(
        kind: _TabKind.local,
        title: shell,
        terminal: t,
        pty: p,
      );

  factory _Tab.ssh(Terminal t, SSHClient c, SSHSession s, String title) =>
      _Tab._(
        kind: _TabKind.ssh,
        title: title,
        terminal: t,
        sshClient: c,
        sshSession: s,
      );

  factory _Tab.sftp(SftpClient sftp, SSHClient c, String host) => _Tab._(
        kind: _TabKind.sftp,
        title: host,
        sftp: sftp,
        sshClient: c,
        sftpHost: host,
      );

  void dispose() {
    pipe?.dispose();
    pty?.kill();
    sshSession?.close();
    sshClient?.close();
  }

  IconData get icon => switch (kind) {
        _TabKind.local => Icons.terminal,
        _TabKind.ssh => Icons.lock_outline,
        _TabKind.sftp => Icons.folder_outlined,
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

  @override
  void initState() {
    super.initState();
    _newLocalTab();
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

  Future<void> _showConnectDialog() async {
    final result = await showConnectDialog(context);
    if (result == null || !mounted) return;

    if (result.mode == ConnectMode.terminal) {
      _openSshTerminal(result);
    } else {
      _openSftpBrowser(result);
    }
  }

  void _openSshTerminal(ConnectResult r) {
    final terminal = Terminal(maxLines: 5000);
    final session = r.session!;

    // Bind both stdout and stderr so backpressure never stalls the SSH stream.
    final pipe = _OutputPipe(terminal)
      ..bind(session.stdout)
      ..bind(session.stderr);

    terminal.onOutput = (d) => session.stdin.add(utf8.encode(d));
    terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h);

    session.done.then((_) {
      if (mounted) terminal.write('\r\n[SSH session closed]\r\n');
    });

    setState(() {
      final tab = _Tab.ssh(terminal, r.client, session, '${r.username}@${r.host}');
      tab.pipe = pipe;
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
  }

  void _openSftpBrowser(ConnectResult r) {
    setState(() {
      _tabs.add(_Tab.sftp(r.sftp!, r.client, r.host));
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: Column(
        children: [
          _TabBar(
            tabs: _tabs,
            active: _active,
            onSelect: (i) => setState(() => _active = i),
            onClose: _closeTab,
            onNewLocal: _newLocalTab,
            onNewSsh: _showConnectDialog,
          ),
          const Divider(height: 1, thickness: 1, color: _kDivider),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    final tab = _tabs[_active];
    return switch (tab.kind) {
      _TabKind.local || _TabKind.ssh => TerminalView(
          tab.terminal!,
          theme: _kTheme,
          textStyle: const TerminalStyle(fontSize: 13.5, fontFamily: 'Monaco'),
          padding: const EdgeInsets.all(6),
          autofocus: true,
          hardwareKeyboardOnly: true,
        ),
      _TabKind.sftp => SftpView(
          key: ValueKey(tab.sftpHost),
          sftp: tab.sftp!,
          host: tab.sftpHost!,
        ),
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
  });

  final List<_Tab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNewLocal;
  final VoidCallback onNewSsh;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      color: _kTabBarBg,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    _TabChip(
                      tab: tabs[i],
                      isActive: i == active,
                      showClose: tabs.length > 1,
                      onTap: () => onSelect(i),
                      onClose: () => onClose(i),
                    ),
                ],
              ),
            ),
          ),
          _PlusMenu(onLocal: onNewLocal, onSsh: onNewSsh),
          const SizedBox(width: 4),
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
    required this.onTap,
    required this.onClose,
  });

  final _Tab tab;
  final bool isActive;
  final bool showClose;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
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
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(tab.icon,
                size: 11,
                color: isActive ? _kFgActive : _kFgInactive),
            const SizedBox(width: 5),
            Text(
              tab.title,
              style: TextStyle(
                color: isActive ? _kFgActive : _kFgInactive,
                fontSize: 12,
                fontWeight:
                    isActive ? FontWeight.w500 : FontWeight.normal,
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
  const _PlusMenu({required this.onLocal, required this.onSsh});
  final VoidCallback onLocal;
  final VoidCallback onSsh;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'New tab',
      color: const Color(0xFF2B2B2B),
      offset: const Offset(0, 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: _kDivider),
      ),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'local',
          height: 36,
          child: Row(children: [
            const Icon(Icons.terminal, size: 13, color: _kFgInactive),
            const SizedBox(width: 8),
            const Text('New Local Terminal',
                style: TextStyle(color: _kFgActive, fontSize: 13)),
          ]),
        ),
        PopupMenuItem(
          value: 'ssh',
          height: 36,
          child: Row(children: [
            const Icon(Icons.lock_outline, size: 13, color: _kFgInactive),
            const SizedBox(width: 8),
            const Text('New SSH Connection…',
                style: TextStyle(color: _kFgActive, fontSize: 13)),
          ]),
        ),
      ],
      onSelected: (v) {
        if (v == 'local') onLocal();
        if (v == 'ssh') onSsh();
      },
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        child: const Icon(Icons.add, size: 15, color: _kFgInactive),
      ),
    );
  }
}
