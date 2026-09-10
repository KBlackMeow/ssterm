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
  final _localShellLoginEnvironmentResolver = LoginShellEnvironmentResolver();
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
    capabilities: TerminalCapabilities(
      backgroundRgb:
          _config.terminal.resolveTheme().background.toARGB32() & 0xffffff,
    ),
  );

  RustTerminalCore? _openRustTerminalCore({
    required int columns,
    required int rows,
  }) {
    // Rust is the production parser and screen authority. xterm is retained
    // only as the Flutter painting/input surface and receives packed native
    // screen snapshots through RustTerminalBridge. Keep one explicit rollback
    // switch for diagnosing platform-specific native-loader problems.
    if (Platform.environment['SSTERM_DART_TERMINAL_CORE'] == '1' ||
        Platform.environment['SSTERM_RUST_TERMINAL_CORE'] == '0') {
      return null;
    }
    try {
      return RustTerminalCore.open(
        columns: columns,
        rows: rows,
        // xterm's `maxLines` includes the visible viewport, while the native
        // core's limit counts history only.
        maxScrollbackRows: rows >= 5000 ? 0 : 5000 - rows,
        backgroundRgb:
            _config.terminal.resolveTheme().background.toARGB32() & 0xffffff,
      );
    } catch (_) {
      // An unavailable optional dylib must not prevent a user from opening a
      // shell if a platform bundle is missing the native library.
      return null;
    }
  }

  RustTerminalBridge? _openRustTerminalBridge({
    required Terminal terminal,
    required void Function(Uint8List bytes) onResponseBytes,
    void Function(String path)? onWorkingDirectoryChange,
  }) {
    final core = _openRustTerminalCore(
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    return core == null
        ? null
        : RustTerminalBridge(
            core: core,
            terminal: terminal,
            onResponseBytes: onResponseBytes,
            onWorkingDirectoryChange: onWorkingDirectoryChange,
          );
  }

  void _syncPaneAfterShown(_Tab tab, {required int pane}) {
    if (pane == 1) {
      tab.splitViewKey.currentState?.syncAfterShown();
      tab.splitPipe?.releaseHeldOutput();
      return;
    }
    tab.terminalViewKey.currentState?.syncAfterShown();
    tab.pipe?.releaseHeldOutput();
  }

  void _scheduleSyncPaneAfterShown(_Tab tab, {required int pane}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPaneAfterShown(tab, pane: pane);
    });
  }

  Future<Map<String, String>> _environmentForLocalShell(
    LocalShellOption shell,
  ) async {
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
    final env = Platform.isMacOS || Platform.isLinux
        ? await buildLocalShellEnvironmentWithLoginPath(
            shell: shell,
            extras: shell.environment,
            loginEnvironmentResolver: _localShellLoginEnvironmentResolver,
          )
        : buildLocalShellEnvironment(extras: shell.environment);
    if (shell.id == 'cmd') {
      env['PROMPT'] = buildCmdOsc7Prompt(Platform.environment['PROMPT']);
    }
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
    tab.noteRemoteCwd(pane: pane, cwd: cwd);
  }

  void _writeTerminalOutput(_Tab tab, Terminal? terminal, String text) {
    if (terminal == null || text.isEmpty) return;
    final pane = _paneIndexOf(tab, terminal);
    final bridge = pane == 1
        ? tab.splitRustTerminalBridge
        : pane == 0
        ? tab.rustTerminalBridge
        : null;
    if (bridge != null) {
      bridge.write(utf8.encode(text));
    } else {
      terminal.write(text);
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
      final splitSession = tab.splitSshSession;
      if (splitSession != null) safeSshTeardown(() => splitSession.close());
      tab.splitSshSession = null;
    } else {
      tab.pty = null;
      tab.pipe?.dispose();
      tab.pipe = null;
      final session = tab.sshSession;
      if (session != null) safeSshTeardown(() => session.close());
      tab.sshSession = null;
    }

    if (ssh) {
      terminal.onResize = null;
    }

    // Reset terminal state that the exiting process may have left dirty.
    // On Windows especially, processes (Claude Code, etc.) sometimes exit
    // without sending cleanup sequences, leaving the terminal in alt-buffer
    // mode, with SGR underline set, or with mouse/cursor modes active.
    if (terminal.isUsingAltBuffer) {
      _writeTerminalOutput(
        tab,
        terminal,
        '\x1b[?1049l',
      ); // exit alt buffer + restore cursor
    }
    _writeTerminalOutput(
      tab,
      terminal,
      '\x1b[m' // reset all SGR attributes (underline, bold, etc.)
      '\x1b[?25h' // show cursor (in case it was hidden)
      '\x1b[?1l' // normal cursor keys (not application mode)
      '\x1b[?1000l' // disable mouse reporting
      '\x1b[?1002l'
      '\x1b[?1003l'
      '\x1b[?1006l', // disable SGR mouse encoding
    );

    if (showExitMessage && exitCode != null && !ssh) {
      _writeTerminalOutput(
        tab,
        terminal,
        '\r\n[Process exited with code $exitCode]\r\n',
      );
    }
    if (ssh) {
      _writeTerminalOutput(tab, terminal, '\r\n[SSH connection closed]\r\n');
    }

    final paneNow = _paneIndexOf(tab, terminal) ?? pane;
    if (tab.isSplit) {
      _collapseSplitAfterExit(tab, paneIndex: paneNow);
      return;
    }

    _writeTerminalOutput(tab, terminal, _kRestartPrompt);
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
    final env = await _environmentForLocalShell(shell);
    final rustTerminalCore = _openRustTerminalCore(
      columns: columns,
      rows: rows,
    );
    late Pty pty;
    final rustTerminalBridge = rustTerminalCore == null
        ? null
        : RustTerminalBridge(
            core: rustTerminalCore,
            terminal: terminal,
            onResponseBytes: (bytes) => pty.write(bytes),
          );
    try {
      pty = await Pty.start(
        shell.executable,
        // WSL keeps only its distribution selector. No selected shell receives
        // startup arguments; cwd integration is installed over PTY input.
        arguments: shell.isWsl
            ? shell.arguments
            : localShellStartupArguments(shell.executable),
        columns: columns,
        rows: rows,
        environment: env,
        workingDirectory: shell.isWsl ? null : (workingDirectory ?? home),
        ackRead: true,
      );
    } catch (e) {
      rustTerminalBridge?.close();
      rustTerminalCore?.close();
      if (!mounted) return;
      terminal.write('\r\n[Failed to start shell: $e]\r\n$_kRestartPrompt');
      _setPaneSessionEnded(tab, pane, true);
      return;
    }

    // Only kill/dispose the old PTY after the new one is confirmed working.
    if (isSplit) {
      tab.splitPty?.kill();
      tab.splitPty?.dispose();
      tab.splitRustTerminalBridge?.close();
      tab.splitRustTerminalCore?.close();
      tab.splitPty = pty;
      tab.splitRustTerminalBridge = rustTerminalBridge;
      tab.splitRustTerminalCore = rustTerminalCore;
    } else {
      tab.pty?.kill();
      tab.pty?.dispose();
      tab.rustTerminalBridge?.close();
      tab.rustTerminalCore?.close();
      tab.pty = pty;
      tab.rustTerminalBridge = rustTerminalBridge;
      tab.rustTerminalCore = rustTerminalCore;
    }

    final cwdParser = RemoteCwdParser();
    final pipe = OutputPipe(
      terminal,
      holdOutputUntilRelease: true,
      onBytesAccepted: (_) => pty.ackRead(),
      terminalByteSink: rustTerminalBridge,
      transform: (bytes) {
        if (rustTerminalBridge != null) {
          var cwd = cwdParser.observe(bytes);
          if (cwd != null && Platform.isWindows) {
            final drive = RegExp(r'^/([A-Za-z]:.*)$').firstMatch(cwd);
            if (drive != null) cwd = drive.group(1)!.replaceAll('/', r'\');
          }
          if (cwd != null &&
              tab.localPath != null &&
              !tab.manuallyDisconnected) {
            tab.localPath!.value = cwd;
            tab.agentCwd = cwd;
          }
          return bytes;
        }
        final parsed = cwdParser.process(bytes);
        var cwd = parsed.cwd;
        // PowerShell's OSC 7 prelude reports cwd in POSIX shape
        // (`/C:/Users/foo`, see powershell_shell_wrapper.dart) since the
        // OSC7 URI convention has no native drive-letter form; native
        // Windows child processes (Pty.start on _restartSession) need
        // `C:\Users\foo` instead.
        if (cwd != null && Platform.isWindows) {
          final drive = RegExp(r'^/([A-Za-z]:.*)$').firstMatch(cwd);
          if (drive != null) cwd = drive.group(1)!.replaceAll('/', r'\');
        }
        if (cwd != null && tab.localPath != null && !tab.manuallyDisconnected) {
          tab.localPath!.value = cwd;
          // Keep the Agent's independent execution context aligned with the
          // visible local shell. SSH tabs do this through noteRemoteCwd(); the
          // local OSC-7 path must update both consumers as well.
          tab.agentCwd = cwd;
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
    _scheduleSyncPaneAfterShown(tab, pane: pane);

    // After ^C, some apps (notably Claude Code's initial trust prompt) leave
    // SGR state and footer rows behind on Windows/ConPTY. Give PowerShell time
    // to draw its prompt, then clear everything below that prompt. Full-screen
    // apps are protected by the alt-buffer check.
    Timer? ctrlCCleanupTimer;

    _bindTerminalInput(
      terminal,
      tab,
      forward: (d) {
        if (d.contains('\x03')) {
          ctrlCCleanupTimer?.cancel();
          ctrlCCleanupTimer = Timer(const Duration(milliseconds: 300), () {
            ctrlCCleanupTimer = null;
            if (!mounted) return;
            final recoverWindowsMainBuffer =
                Platform.isWindows && !terminal.isUsingAltBuffer;
            _writeTerminalOutput(
              tab,
              terminal,
              '\x1b[m\x1b[?25h'
              '${recoverWindowsMainBuffer ? '\x1b[J' : ''}',
            );
            if (recoverWindowsMainBuffer) {
              // SGR 0 only fixes future writes. Claude/Ink may already have
              // repainted older PowerShell rows with its leaked underline.
              terminal.clearBufferTextAttributes(CellAttr.underline);
            }
          });
        }
        pty.write(utf8.encode(d));
      },
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
        unawaited(
          _spawnLocalPty(
            tab: tab,
            terminal: terminal,
            shell: shell,
            columns: w,
            rows: h,
            workingDirectory: workingDirectory,
            pane: pane,
            showExitMessage: showExitMessage,
          ),
        );
      } else if (activePty != null) {
        activePty.resize(h, w);
        final rustTerminalBridge = pane == 1
            ? tab.splitRustTerminalBridge
            : tab.rustTerminalBridge;
        rustTerminalBridge?.resize(w, h);
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
      tab.pipe?.dispose();
      tab.pipe = null;
      final session = tab.sshSession;
      if (session != null) safeSshTeardown(() => session.close());
      tab.sshSession = null;
      _handlePaneExited(tab, terminal: terminal, pane: 0, ssh: true);
      return;
    }

    if (pane == 0 && prof != null && prof.autoReconnect) {
      terminal.onResize = null;
      tab.pipe?.dispose();
      tab.pipe = null;
      final session = tab.sshSession;
      if (session != null) safeSshTeardown(() => session.close());
      tab.sshSession = null;
      _writeTerminalOutput(tab, terminal, '\r\n[SSH connection closed]\r\n');
      _writeTerminalOutput(tab, terminal, '[Reconnecting in 3 seconds…]\r\n');
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted || tab.manuallyDisconnected) return;
      await _reconnectTab(tab);
      return;
    }

    if (tab.isSplit && pane == 1) {
      tab.splitPipe?.dispose();
      tab.splitPipe = null;
      final splitSession = tab.splitSshSession;
      if (splitSession != null) safeSshTeardown(() => splitSession.close());
      tab.splitSshSession = null;
      _handlePaneExited(tab, terminal: terminal, pane: 1, ssh: true);
      return;
    }

    tab.pipe?.dispose();
    tab.pipe = null;
    final session = tab.sshSession;
    if (session != null) safeSshTeardown(() => session.close());
    tab.sshSession = null;
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
        _writeTerminalOutput(
          tab,
          terminal,
          '[Not connected]\r\n$_kRestartPrompt',
        );
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
      final rustTerminalBridge = _openRustTerminalBridge(
        terminal: terminal,
        onResponseBytes: (bytes) => session.stdin.add(bytes),
        onWorkingDirectoryChange: (cwd) => _noteRemoteCwd(tab, pane, cwd),
      );
      final pipe = OutputPipe(
        terminal,
        holdOutputUntilRelease: true,
        pauseSourceOnBackpressure: false,
        terminalByteSink: rustTerminalBridge,
        transform: rustTerminalBridge == null
            ? _sshOutputTransform(tab, pane, cwdParser)
            : null,
      );

      _bindTerminalInput(
        terminal,
        tab,
        forward: (d) => session.stdin.add(utf8.encode(d)),
      );
      terminal.onResize = (w, h, pw, ph) {
        session.resizeTerminal(w, h);
        rustTerminalBridge?.resize(w, h);
      };

      pipe.bind(session.stdout);
      pipe.bind(session.stderr);

      if (pane == 1) {
        tab.splitSshSession?.close();
        tab.splitSshSession = session;
        tab.splitPipe?.dispose();
        tab.splitRustTerminalBridge?.close();
        tab.splitRustTerminalCore?.close();
        tab.splitPipe = pipe;
        tab.splitRustTerminalBridge = rustTerminalBridge;
        tab.splitRustTerminalCore = rustTerminalBridge?.core;
      } else {
        tab.sshSession?.close();
        tab.sshSession = session;
        tab.pipe?.dispose();
        tab.rustTerminalBridge?.close();
        tab.rustTerminalCore?.close();
        tab.pipe = pipe;
        tab.rustTerminalBridge = rustTerminalBridge;
        tab.rustTerminalCore = rustTerminalBridge?.core;
      }
      _scheduleSyncPaneAfterShown(tab, pane: pane);

      session.done.then(
        (_) => _handleSshSessionDone(tab, terminal, profile: tab.sshProfile),
      );
    } catch (e) {
      if (!mounted) return;
      // Transport died (VPN switch, etc.) but [sshClient] was still set —
      // fall back to a full reconnect instead of reusing the dead client.
      if (tab.sshProfile != null) {
        tab.clearDeadSshTransport();
        try {
          await _reconnectTab(tab);
        } catch (e2) {
          if (!mounted) return;
          _writeTerminalOutput(
            tab,
            terminal,
            '[Reconnect failed: $e2]\r\n$_kRestartPrompt',
          );
          _setPaneSessionEnded(tab, pane, true);
        }
        return;
      }
      _writeTerminalOutput(
        tab,
        terminal,
        '[Reconnect failed: $e]\r\n$_kRestartPrompt',
      );
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
        if (!mounted) return;
        _syncPaneAfterShown(tab, pane: 0);
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
        if (w >= 1 && h >= 1) {
          tab.pty!.resize(h, w);
          tab.rustTerminalBridge?.resize(w, h);
        }
      };
    } else if (tab.sshSession != null) {
      _bindTerminalInput(
        terminal,
        tab,
        forward: (d) => tab.sshSession!.stdin.add(utf8.encode(d)),
      );
      terminal.onResize = (w, h, pw, ph) {
        tab.sshSession!.resizeTerminal(w, h);
        tab.rustTerminalBridge?.resize(w, h);
      };
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPaneAfterShown(tab, pane: 0);
    });
  }

  void _wireSshSession(
    _Tab tab,
    SSHSession session,
    Terminal terminal,
    OutputPipe pipe, {
    required bool isSplit,
    RustTerminalBridge? rustTerminalBridge,
    SshHost? profile,
  }) {
    _bindTerminalInput(
      terminal,
      tab,
      forward: (d) => session.stdin.add(utf8.encode(d)),
    );
    terminal.onResize = (w, h, pw, ph) {
      session.resizeTerminal(w, h);
      rustTerminalBridge?.resize(w, h);
    };
    session.done.then(
      (_) => _handleSshSessionDone(tab, terminal, profile: profile),
    );
  }

  void _newLocalTab(LocalShellOption shell) {
    final home = userHomeDir();
    // The Windows HOME is not meaningful inside a WSL distribution.  Keep a
    // POSIX cwd sentinel; the WSL adapter resolves `~` in that distribution.
    final agentCwd = shell.isWsl ? '~' : (home ?? '/');
    final tab = _Tab.local(title: shell.displayName, shell: shell)
      ..terminal = _createTerminal()
      ..localPath = ValueNotifier<String>(home ?? '/')
      ..agentCwd = agentCwd;
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
