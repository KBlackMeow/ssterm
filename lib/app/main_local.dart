part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Local shell business logic — PTY spawning, session wiring, split-pane
// management for local (non-SSH) terminals.
// ─────────────────────────────────────────────────────────────────────────────

abstract class _TerminalHomeLocalMethods extends State<TerminalHome> {
  // ── State fields ───────────────────────────────────────────────────────────
  final List<_Tab> _tabs = [];
  int _active = 0;
  List<SshHost> _savedHosts = [];
  List<SshHost> _configHosts = [];
  List<LocalShellOption> _localShells = LocalShellDiscovery.discoverSync();
  AppConfig _config = AppConfig();
  int _mobileTabIndex = 0; // 0=terminal 1=files 2=commands 3=settings

  // ── Abstract stubs (implemented in _TerminalHomeSshMethods) ───────────────
  void _activateTab(int i);
  Future<void> _reconnectTab(_Tab tab);

  // ── Shell-list refresh ─────────────────────────────────────────────────────

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

  // ── Local terminal ─────────────────────────────────────────────────────────

  Terminal _createTerminal({bool reflowEnabled = true}) => Terminal(
    maxLines: 5000,
    platform: detectTerminalHostPlatform(),
    reflowEnabled: reflowEnabled,
  );

  Map<String, String> _environmentForLocalShell(LocalShellOption shell) {
    if (shell.isWsl) {
      return buildWslEnvironment(
        systemRoot: Platform.environment['SystemRoot'] ?? r'C:\Windows',
      );
    }
    if (shell.id.startsWith('git-bash')) {
      return buildGitBashEnvironment(
        executable: shell.executable,
        systemRoot: Platform.environment['SystemRoot'] ?? r'C:\Windows',
        extras: shell.environment,
      );
    }
    final env = buildLocalShellEnvironment(extras: shell.environment);
    if (shell.useUnixWrapper) env['SHELL'] = shell.executable;
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
    if (tab.manuallyDisconnected) return;
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
      final home = userHomeDir();
      await _spawnLocalPty(
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

  Future<void> _spawnLocalPty({
    required _Tab tab,
    required Terminal terminal,
    required LocalShellOption shell,
    required int columns,
    required int rows,
    String? workingDirectory,
    required int pane,
    bool showExitMessage = true,
  }) async {
    if (columns < 1 || rows < 1) return;

    final isSplit = pane == 1;
    final home = userHomeDir();
    final env = _environmentForLocalShell(shell);
    final useUnixWrapper = shell.useUnixWrapper && !Platform.isWindows;

    final Pty pty;
    try {
      if (useUnixWrapper) {
        // On iOS login-shell flag (-l) causes /bin/sh to source system profile
        // files that don't exist in the iOS sandbox, hanging the shell startup.
        final shArgs = Platform.isIOS
            ? ['-c', _interactiveLocalShellWrapperCommand()]
            : ['-lc', _interactiveLocalShellWrapperCommand()];
        pty = await Pty.start(
          '/bin/sh',
          arguments: shArgs,
          columns: columns,
          rows: rows,
          environment: env,
          workingDirectory: workingDirectory ?? home,
        );
      } else {
        pty = await Pty.start(
          shell.executable,
          arguments: shell.arguments,
          columns: columns,
          rows: rows,
          environment: env,
          workingDirectory: shell.isWsl ? null : (workingDirectory ?? home),
        );
      }
    } catch (e) {
      if (!mounted) return;
      terminal.write(
        '\r\n[Failed to start shell: $e]\r\n$_kRestartPrompt',
      );
      _setPaneSessionEnded(tab, pane, true);
      return;
    }

    // Only kill/dispose the old PTY after the new one is confirmed working.
    if (isSplit) {
      tab.splitPty?.kill();
      tab.splitPty?.dispose();
      tab.splitPty = pty;
    } else {
      tab.pty?.kill();
      tab.pty?.dispose();
      tab.pty = pty;
    }

    final cwdParser = RemoteCwdParser();
    final pipe = OutputPipe(
      terminal,
      transform: (bytes) {
        final parsed = cwdParser.process(bytes);
        if (parsed.cwd != null &&
            tab.localPath != null &&
            !tab.manuallyDisconnected) {
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
      if (!mounted) return;
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
        // Use unawaited since onResize is a synchronous void callback.
        // _spawnLocalPty handles its own errors via internal try/catch.
        unawaited(_spawnLocalPty(
          tab: tab,
          terminal: terminal,
          shell: shell,
          columns: w,
          rows: h,
          workingDirectory: workingDirectory,
          pane: pane,
          showExitMessage: showExitMessage,
        ));
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
      final pipe = OutputPipe(
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
    OutputPipe pipe, {
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

  String _interactiveLocalShellWrapperCommand() =>
      buildInteractiveShellWrapper();

  void _newLocalTab(LocalShellOption shell) {
    final home = userHomeDir();
    final tab = _Tab.local(title: shell.displayName, shell: shell)
      ..terminal = _createTerminal()
      ..localPath = ValueNotifier<String>(home ?? '/');
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
}
