part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SSH business logic — connection lifecycle, SFTP, split-pane SSH sessions,
// reconnect, keepalive, port forwarding, and saved-host management.
// ─────────────────────────────────────────────────────────────────────────────

abstract class _TerminalHomeSshMethods extends _TerminalHomeLocalMethods {

  // ── Host list ──────────────────────────────────────────────────────────────

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

  // ── SSH / SFTP ─────────────────────────────────────────────────────────────

  Future<void> _showConnectDialog({SshHost? initialHost, required BuildContext ctx}) async {
    final profile = await showConnectDialog(
      ctx,
      initialHost: initialHost,
    );
    if (profile == null || !mounted) return;
    await _rememberHostProfile(profile);
    if (!mounted) return;
    _openConnectingTab(profile);
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

  void _connectSavedHost(SshHost host) {
    _openConnectingTab(host);
  }

  /// Inserts a tab in the [_TabKind.sshConnecting] state immediately and runs
  /// the connection in the background. The rest of the UI stays interactive
  /// (other tabs can be selected / used) while the handshake completes.
  void _openConnectingTab(SshHost profile) {
    final tab = _Tab.connecting(profile);
    setState(() {
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
    unawaited(_runConnectionForTab(tab));
  }

  /// 弹出密码输入框；勾选记住时存入 Keychain 并更新 tab profile。
  Future<String?> _askPassword(_Tab tab, SshHost profile) async {
    if (!mounted) return null;
    final r = await showPasswordPromptDialog(context, profile);
    if (r == null) return null;
    if (r.save) {
      await CredentialStorage.store(profile.profileKey, r.password);
      tab.sshProfile = profile.copyWith(password: r.password);
    }
    return r.password;
  }

  Future<void> _runConnectionForTab(_Tab tab) async {
    final profile = tab.sshProfile;
    if (profile == null) return;

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
        onPasswordNeeded: () => _askPassword(tab, profile),
      );

      if (!mounted || tab.manuallyDisconnected || !_tabs.contains(tab)) {
        result.session?.close();
        result.client.close();
        result.jumpClient?.close();
        return;
      }
      await _materializeSshTab(tab, result);
    } catch (e) {
      if (!mounted || tab.manuallyDisconnected || !_tabs.contains(tab)) return;
      setState(() {
        tab.kind = _TabKind.sshError;
        tab.connectionError = friendlyConnectError(e);
      });
    }
  }

  /// Transforms a placeholder [tab] (in [_TabKind.sshConnecting]) into a fully
  /// wired SSH tab once [connectSshHost] has produced a session.
  Future<void> _materializeSshTab(_Tab tab, ConnectResult r) async {
    final terminal = _createTerminal(reflowEnabled: false);
    final session = r.session!;
    final remotePath = ValueNotifier<String>('');

    SessionLogger? logger;
    if (r.profile.sessionLog) {
      try {
        logger = await SessionLogger.create(r.alias);
      } catch (_) {}
    }

    if (!mounted || tab.manuallyDisconnected) {
      logger?.close();
      remotePath.dispose();
      session.close();
      r.client.close();
      r.jumpClient?.close();
      return;
    }

    final cwdParser = RemoteCwdParser();
    final pipe = OutputPipe(
      terminal,
      logSink: logger,
      transform: _sshOutputTransform(tab, 0, cwdParser),
    );

    SftpClient? sftp;
    TransferManager? transferManager;
    try {
      sftp = await r.client.sftp();
      transferManager = TransferManager(sshProfile: r.profile);
      remotePath.value = await fetchRemoteHome(r.client);
    } catch (_) {
      remotePath.value = '/';
    }

    if (!mounted || tab.manuallyDisconnected) {
      pipe.dispose();
      remotePath.dispose();
      transferManager?.dispose();
      session.close();
      r.client.close();
      r.jumpClient?.close();
      return;
    }

    // Populate tab fields and wire input/resize before [setState] so the new
    // TerminalView sees a fully-configured Terminal when it mounts — matches
    // the order used by the previous _openSshTerminal path.
    tab.terminal = terminal;
    tab.sshClient = r.client;
    tab.jumpClient = r.jumpClient;
    tab.sshSession = session;
    tab.sftp = sftp;
    tab.transferManager = transferManager;
    tab.remotePath = remotePath;
    tab.remoteCwdPane0 = remotePath.value;
    tab.sshProfile = r.profile;
    tab.activeSshPane = 0;
    tab.pipe = pipe;
    tab.connectionError = null;
    tab.primarySessionEnded = false;

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
      tab.kind = _TabKind.ssh;
      tab.title = r.alias;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      pipe.bind(session.stdout);
      pipe.bind(session.stderr);
    });

    final idx = _tabs.indexOf(tab);
    if (idx == _active) _activateTab(idx);
  }

  void _retryConnectingTab(_Tab tab) {
    if (tab.sshProfile == null) return;
    setState(() {
      tab.kind = _TabKind.sshConnecting;
      tab.connectionError = null;
    });
    unawaited(_runConnectionForTab(tab));
  }

  Future<void> _editAndRetryConnectingTab(_Tab tab, {required BuildContext ctx}) async {
    final profile = tab.sshProfile;
    if (profile == null) return;
    final updated = await showConnectDialog(
      ctx,
      initialHost: profile,
    );
    if (updated == null || !mounted) return;
    await _rememberHostProfile(updated);
    if (!mounted) return;
    setState(() {
      tab.sshProfile = updated;
      tab.title = updated.alias;
      tab.kind = _TabKind.sshConnecting;
      tab.connectionError = null;
    });
    unawaited(_runConnectionForTab(tab));
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
    final pipe = OutputPipe(
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

  // ── Reconnect ──────────────────────────────────────────────────────────────

  @override
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
        onPasswordNeeded: () => _askPassword(tab, profile),
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

      final pipe = OutputPipe(
        tab.terminal!,
        logSink: logger,
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
        tab.terminal?.write('[Reconnect failed: $e]\r\n${_TerminalHomeLocalMethods._kRestartPrompt}');
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
    if (i < 0 || i >= _tabs.length) return;
    _tabs[i].dispose();
    setState(() {
      _tabs.removeAt(i);
      if (_tabs.isNotEmpty) {
        if (i < _active) {
          _active--;
        } else {
          _active = _active.clamp(0, _tabs.length - 1);
        }
      } else {
        _active = 0;
      }
    });
    if (_tabs.isNotEmpty) _activateTab(_active);
  }

  void _selectTab(int i) {
    if (i == _active) return;
    setState(() => _active = i);
    _activateTab(i);
  }

  @override
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

  /// Returns whether the active pane currently has OSC 133 shell integration
  /// active.  Used by the AI panel to surface the capture-path indicator.
  bool? _activePaneHasShellIntegration(_Tab tab) {
    final isSplitPane = tab.isSplit && tab.activeSshPane == 1;
    final pipe = isSplitPane ? tab.splitPipe : tab.pipe;
    if (pipe == null) return null;
    return pipe.hasOsc133;
  }

  /// Returns a closure that executes [cmd] on the given [tab].
  /// Honors split panes — sends to the active pane's session/pty.
  void Function(String) _executeOnTab(_Tab tab) {
    return (String cmd) {
      // Strip a trailing newline so we never send `\n\n` (which would run
      // the command and then submit an empty line, polluting prompt /
      // OSC 133 boundaries).  The command always needs ONE trailing
      // newline to actually execute; we add it ourselves below.
      while (cmd.endsWith('\n')) {
        cmd = cmd.substring(0, cmd.length - 1);
      }
      final data = utf8.encode('$cmd\n');
      final isSplitPane = tab.isSplit && tab.activeSshPane == 1;
      if (isSplitPane && tab.splitSshSession != null) {
        tab.splitSshSession!.stdin.add(data);
      } else if (isSplitPane && tab.splitPty != null) {
        tab.splitPty!.write(data);
      } else if (tab.sshSession != null) {
        tab.sshSession!.stdin.add(data);
      } else if (tab.pty != null) {
        tab.pty!.write(data);
      } else {
        final targetTerm = isSplitPane ? tab.splitTerminal : tab.terminal;
        targetTerm?.paste('$cmd\n');
      }
    };
  }

  /// Wraps a multi-line command in `<shell> -c '<cmd>'` so the user shell
  /// sees EXACTLY ONE command — and therefore emits exactly one OSC 133
  /// C/D pair.  Without this, each line of [cmd] would trigger its own
  /// preexec/precmd cycle and the outputs would interleave, corrupting
  /// capture.
  ///
  /// `<shell>` is `\${SSTM_SHELL_BIN:-sh}` — the user's real shell when
  /// the wrapper exported it (bash / zsh), and POSIX `sh` as the universal
  /// fallback (Alpine, Termux, zsh-only systems where `bash` may be
  /// absent).  The lookup happens INSIDE the user shell at the moment we
  /// send the bytes, so we pick up whatever value is currently in scope.
  ///
  /// Single-line commands pass through unchanged so user aliases and
  /// shell-rc state remain available (which `<shell> -c` would NOT see).
  String _toSingleShellLine(String cmd) {
    if (!cmd.contains('\n')) return cmd;
    // POSIX-safe: close the single-quoted region, escape one `'`, reopen.
    final escaped = cmd.replaceAll("'", "'\\''");
    return r"${SSTM_SHELL_BIN:-sh} -c '" "$escaped" "'";
  }

  /// Executes [cmd] on [tab]'s active pane, waits for it to finish, and
  /// returns the captured stdout/stderr along with the exit code.
  ///
  /// Capture strategy (industry-standard, in order):
  ///   1. Shell integration via OSC 133 (preferred): ssterm's wrapper installs
  ///      `OSC 133;C` (preexec) and `OSC 133;D;<exit_code>` (precmd) hooks for
  ///      both bash and zsh.  [OutputPipe] buffers the bytes between C and D,
  ///      strips ANSI, and exposes the result via [OutputPipe.awaitNextCommand].
  ///      This gives the agent clean stdout PLUS the exact exit code — same
  ///      protocol used by iTerm2, VS Code, Warp, and Zed.
  ///   2. Echo-sentinel fallback: for shells where the hooks aren't installed
  ///      (dash, fish, login banners that don't run our rc), append
  ///      `; echo __SSTM_<id>__` to the command and poll the rendered terminal
  ///      buffer until the sentinel appears.  Less precise (no exit code, ANSI
  ///      noise) but works on any POSIX shell.
  ///
  /// [isCancelled] is polled each iteration for responsive cancellation.
  Future<CommandResult?> _executeAndCapture(
    _Tab tab,
    String cmd, {
    bool Function()? isCancelled,
  }) async {
    final isSplitPane = tab.isSplit && tab.activeSshPane == 1;
    final term = isSplitPane ? tab.splitTerminal : tab.terminal;
    final pipe = isSplitPane ? tab.splitPipe : tab.pipe;
    if (term == null) return null;

    // Pre-flight #1: alt-screen TUI detection.
    //
    // `CommandSafety.reason` only sees the COMMAND STRING the agent wants
    // to run, so it can't catch the case where the USER is already inside
    // vim/less/tmux/htop and then triggers the agent.  In that situation
    // anything we send hits the running TUI as keystrokes (chaos: `ls`
    // becomes `l` + `s` in vim normal mode, silently mutating the open
    // file), the OSC 133 D marker never fires, and the echo-fallback
    // path waits the full 120 s timeout while the auto-execute lock
    // prevents the user from escaping the TUI.
    //
    // Detect it via xterm's `isUsingAltBuffer` (set when the program
    // emits `CSI ?1049h`/`?1047h`) and return a synthetic envelope.
    // The wording lives in `CommandSafety.altScreenReason` — see the
    // comment there for why it's a const + co-located with the
    // always-interactive list.
    if (term.isUsingAltBuffer) {
      stdout.writeln(
        '[capture] blocked cmd=${_logQuote(cmd)} reason=alt_screen',
      );
      return CommandResult(
        output: '[ssterm safety check] ${CommandSafety.altScreenReason}',
        exitCode: null,
      );
    }

    // Pre-flight #2: refuse commands that would hang the agent or leak
    // output.  Returning a synthetic CommandResult (instead of throwing)
    // keeps the agent loop deterministic — the LLM gets standard
    // `[Command executed]` feedback and can self-correct on the next turn.
    final safetyReason = CommandSafety.reason(cmd);
    if (safetyReason != null) {
      stdout.writeln(
        '[capture] blocked cmd=${_logQuote(cmd)} reason=${_logQuote(safetyReason)}',
      );
      return CommandResult(
        output: '[ssterm safety check] $safetyReason',
        exitCode: null,
      );
    }

    final wrapped = _toSingleShellLine(cmd);

    // ── 1. Shell-integration capture (OSC 133) ────────────────────────────
    if (pipe != null && pipe.hasOsc133) {
      stdout.writeln('[capture] osc133 start cmd=${_logQuote(cmd)}');
      // Subscribe BEFORE sending so we don't race the next D marker.
      final pending = pipe.awaitNextCommand(isCancelled: isCancelled);
      _executeOnTab(tab)(wrapped);
      final result = await pending;
      if (result == null) {
        stdout.writeln('[capture] osc133 cancelled');
        return null;
      }
      stdout.writeln(
        '[capture] osc133 done exit=${result.exitCode} bytes=${result.output.length}',
      );
      return result;
    }

    // ── 2. Echo-sentinel fallback ────────────────────────────────────────
    final beforeLen = term.buffer.lines.length;
    final marker = '__SSTM_${DateTime.now().microsecondsSinceEpoch}__';
    stdout.writeln(
      '[capture] echo start cmd=${_logQuote(cmd)} marker=$marker',
    );

    // Use a parenthesised group + `printf` so the marker is emitted whether the
    // command exits 0 or non-zero; `; echo` would lose the original $? without
    // saving it first.
    _executeOnTab(tab)('$wrapped; __ssterm_ec=\$?; printf "$marker:%s\\n" "\$__ssterm_ec"');

    final stopwatch = Stopwatch()..start();
    const pollInterval = Duration(milliseconds: 200);
    const maxWait = Duration(seconds: 120);
    var pollCount = 0;

    int? extractExit() {
      final lines = term.buffer.lines;
      for (var i = lines.length - 1; i >= 0 && i >= lines.length - 8; i--) {
        final s = lines[i].toString();
        final idx = s.indexOf('$marker:');
        if (idx >= 0) {
          final tail = s.substring(idx + marker.length + 1);
          final m = RegExp(r'^(\d+)').firstMatch(tail);
          if (m != null) return int.tryParse(m.group(1)!);
          return 0;
        }
      }
      return null;
    }

    int? exitCode;
    while (stopwatch.elapsed < maxWait) {
      if (isCancelled != null && isCancelled()) {
        stdout.writeln('[capture] echo cancelled poll=$pollCount');
        return null;
      }
      await Future<void>.delayed(pollInterval);
      pollCount++;
      exitCode = extractExit();
      if (exitCode != null) break;
    }

    final len = term.buffer.lines.length;
    final totalLines = len - beforeLen;
    // Echo-fallback path: cap at the last 2000 lines of the captured region.
    // If the command produced more, the head is dropped — flag it so the
    // formatter can warn the LLM (mirrors the OSC 133 byte-cap behaviour).
    final cap = beforeLen + 2000;
    final start = len > cap ? len - 2000 : beforeLen;
    final actualStart = start < len ? start : (len > 2000 ? len - 2000 : 0);
    final wasTruncated = totalLines > 2000;
    final buf = <String>[];
    for (var i = actualStart; i < len; i++) {
      final line = term.buffer.lines[i].toString();
      if (line.contains(marker)) continue;
      if (line.contains('__ssterm_ec=')) continue;
      buf.add(line);
    }
    final raw = buf.join('\n');
    final cleaned = stripAnsi(raw).trim();
    // Single done-line that combines both old prints
    // (`echo-marker done` + `returning N lines`) — cuts noise in half.
    stdout.writeln(
      '[capture] echo done exit=$exitCode bytes=${cleaned.length} '
      'lines=${buf.length} polls=$pollCount '
      'elapsed=${stopwatch.elapsedMilliseconds}ms truncated=$wasTruncated',
    );
    return CommandResult(output: cleaned, exitCode: exitCode, truncated: wasTruncated);
  }

  /// Quote a value for safe inclusion in a structured log record — the
  /// counterpart of `_logQuote` in `lib/widgets/ai_assistant_panel.dart`.
  /// Inlined here to avoid pulling a UI-layer file into the SSH widget.
  static String _logQuote(String s) {
    const cap = 120;
    var v = s
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    if (v.length > cap) v = '${v.substring(0, cap)}…';
    return '"$v"';
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
}
