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

  Future<void> _showConnectDialog({
    SshHost? initialHost,
    required BuildContext ctx,
  }) async {
    final profile = await showConnectDialog(ctx, initialHost: initialHost);
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
    if (original != null) {
      await SavedHostsStore.deleteStaleCredentials(original, updated);
    }
    if (mounted) await _loadSshHosts();
  }

  Future<void> _deleteSavedHost(SshHost host) async {
    await SavedHostsStore.deleteHost(host);
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

    // Feature 1: port forwarding.  Errors here used to be `.ignore()`d
    // silently, leaving the user wondering why `-L 8080:…` does nothing —
    // surface them to the terminal and continue (other features still work).
    if (r.profile.forwardRules.isNotEmpty) {
      final fwdService = PortForwardService();
      tab.forwardService = fwdService;
      unawaited(
        fwdService.startAll(r.client, r.profile.forwardRules).catchError((e) {
          if (mounted) {
            tab.terminal?.write('[Port forward error: $e]\r\n');
          }
        }),
      );
    }

    // Feature 4: keepalive.  See `_reconnectTab` for the `keepaliveInFlight`
    // rationale — both call sites need the same in-flight guard.
    if (r.profile.keepaliveInterval > 0) {
      tab.keepaliveInFlight = false;
      tab.keepaliveTimer = Timer.periodic(
        Duration(seconds: r.profile.keepaliveInterval),
        (_) async {
          if (tab.keepaliveInFlight) return;
          tab.keepaliveInFlight = true;
          try {
            await r.client.run('true').timeout(const Duration(seconds: 5));
          } catch (_) {
          } finally {
            tab.keepaliveInFlight = false;
          }
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

  Future<void> _editAndRetryConnectingTab(
    _Tab tab, {
    required BuildContext ctx,
  }) async {
    final profile = tab.sshProfile;
    if (profile == null) return;
    final updated = await showConnectDialog(ctx, initialHost: profile);
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
      final oldSftp = tab.sftp;
      final oldTransferManager = tab.transferManager;
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

      SftpClient? sftp;
      TransferManager? transferManager;
      var remoteHome = tab.remotePath?.value ?? '/';
      try {
        sftp = await result.client.sftp();
        transferManager = TransferManager(sshProfile: result.profile);
        remoteHome = await fetchRemoteHome(result.client);
      } catch (e) {
        tab.terminal?.write('[SFTP unavailable after reconnect: $e]\r\n');
      }

      if (!mounted || tab.manuallyDisconnected) {
        logger?.close();
        sftp?.close();
        transferManager?.dispose();
        result.session?.close();
        result.client.close();
        result.jumpClient?.close();
        return;
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
      tab.sftp = sftp;
      tab.transferManager = transferManager;
      tab.remoteCwdPane0 = remoteHome;
      tab.remoteCwdPane1 = null;
      tab.remotePath?.value = remoteHome;

      oldSftp?.close();
      oldTransferManager?.dispose();
      oldSession?.close();
      oldClient?.close();
      oldJump?.close();

      if (profile.forwardRules.isNotEmpty) {
        final fwdService = PortForwardService();
        tab.forwardService = fwdService;
        unawaited(
          fwdService.startAll(result.client, profile.forwardRules).catchError((
            e,
          ) {
            if (mounted) {
              tab.terminal?.write('[Port forward error: $e]\r\n');
            }
          }),
        );
      }

      if (profile.keepaliveInterval > 0) {
        tab.keepaliveInFlight = false;
        tab.keepaliveTimer = Timer.periodic(
          Duration(seconds: profile.keepaliveInterval),
          (_) async {
            // In-flight guard: drop the tick if the previous `true` is
            // still pending (slow link / unresponsive server) so we don't
            // queue an unbounded backlog of probes on the SSH channel.
            if (tab.keepaliveInFlight) return;
            tab.keepaliveInFlight = true;
            try {
              await result.client
                  .run('true')
                  .timeout(const Duration(seconds: 5));
            } catch (_) {
              // Failures here are expected when the link is degrading —
              // the surrounding session lifecycle will catch the actual
              // disconnect and trigger reconnect.  Don't escalate.
            } finally {
              tab.keepaliveInFlight = false;
            }
          },
        );
      }

      // Success — clear the backoff counter so the NEXT disconnect starts
      // from the bottom of the ladder again.
      tab.reconnectAttempt = 0;
      tab.terminal?.write('[Reconnected]\r\n');
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      tab.terminal?.write(
        '[Reconnect failed: $e]\r\n${_TerminalHomeLocalMethods._kRestartPrompt}',
      );
      tab.primarySessionEnded = true;
      if (tab.sshProfile?.autoReconnect != true || tab.manuallyDisconnected) {
        return;
      }
      // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 60s (cap), 60s, …
      // Hard ceiling at `_kMaxReconnectAttempts` so a permanently-down
      // host doesn't burn cycles forever (and tickle fail2ban / IDS).
      const maxAttempts = _kMaxReconnectAttempts;
      tab.reconnectAttempt += 1;
      if (tab.reconnectAttempt > maxAttempts) {
        tab.terminal?.write(
          '[Reconnect aborted after $maxAttempts attempts — host appears '
          'permanently unreachable. Press a key to retry manually.]\r\n',
        );
        tab.reconnectAttempt = 0;
        return;
      }
      final delaySeconds = (1 << tab.reconnectAttempt).clamp(
        2,
        60,
      ); // 2,4,8,16,32,60,60,…
      tab.terminal?.write(
        '[Retry ${tab.reconnectAttempt}/$maxAttempts in ${delaySeconds}s…]\r\n',
      );
      await Future<void>.delayed(Duration(seconds: delaySeconds));
      if (!mounted || tab.manuallyDisconnected) return;
      _reconnectTab(tab);
    }
  }

  /// Max consecutive reconnect attempts before we stop the auto-reconnect
  /// loop.  At 8 with exponential backoff capped at 60s the total wall-time
  /// is ≈ 2+4+8+16+32+60+60+60 = 242s ≈ 4 minutes — enough to bridge a
  /// laptop-lid event or a Wi-Fi roam, short enough that a truly-down host
  /// stops thrashing.
  static const int _kMaxReconnectAttempts = 8;

  // ── Tab management ─────────────────────────────────────────────────────────

  void _closeTab(int i) {
    if (i < 0 || i >= _tabs.length) return;
    final removed = _tabs[i];
    removed.terminalViewKey.currentState?.releaseInput();
    removed.splitViewKey.currentState?.releaseInput();
    removed.terminalController.disposeSelection();
    removed.splitTerminalController.disposeSelection();
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      removed.dispose();
    });
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
      // Crucially, when the SPLIT pane is active but its session / PTY
      // aren't wired up yet (still connecting, just torn down, …), we
      // MUST NOT fall through to the primary pane's transport.  Doing
      // so would silently execute the agent's command in the wrong
      // shell while `_executeAndCapture` is `awaitNextCommand`-ing the
      // SPLIT pipe — guaranteeing a 120 s timeout and a stale capture.
      // Paste into the split terminal instead, which is visible and
      // makes the broken-pane state obvious to the user.
      if (isSplitPane) {
        if (tab.splitSshSession != null) {
          tab.splitSshSession!.stdin.add(data);
        } else if (tab.splitPty != null) {
          tab.splitPty!.write(data);
        } else {
          tab.splitTerminal?.paste('$cmd\n');
        }
        return;
      }
      if (tab.sshSession != null) {
        tab.sshSession!.stdin.add(data);
      } else if (tab.pty != null) {
        tab.pty!.write(data);
      } else {
        tab.terminal?.paste('$cmd\n');
      }
    };
  }

  /// Sends raw bytes (no trailing newline, no shell quoting) to the active
  /// pane's transport.  Used for control characters like `Ctrl-C`/`Ctrl-D`
  /// that the agent's echo-sentinel fallback needs to fire on timeout.
  ///
  /// Mirrors `_executeOnTab`'s split-pane safety: when the split pane is
  /// active but its session / PTY aren't established, we drop the bytes
  /// rather than route them to the primary pane (which would interrupt
  /// whatever the user is running there).
  void _sendRawToTab(_Tab tab, Uint8List bytes) {
    final isSplitPane = tab.isSplit && tab.activeSshPane == 1;
    if (isSplitPane) {
      if (tab.splitSshSession != null) {
        tab.splitSshSession!.stdin.add(bytes);
      } else if (tab.splitPty != null) {
        tab.splitPty!.write(bytes);
      }
      return;
    }
    if (tab.sshSession != null) {
      tab.sshSession!.stdin.add(bytes);
    } else if (tab.pty != null) {
      tab.pty!.write(bytes);
    }
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
    return r"${SSTM_SHELL_BIN:-sh} -c '"
        "$escaped"
        "'";
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
      // We used to emit a separate `[capture] osc133 start cmd=…` line
      // here and let `done` carry only `exit=` + `bytes=`.  In practice
      // that gave two log lines for every command on the happy path
      // with NO new information on the `start` line — the cmd is far
      // more useful next to the exit code than ahead of it.  We now
      // emit a single `done` line carrying the cmd, exit, and byte
      // count.  Error/timeout/cancel branches still log on their own
      // lines because those carry recovery info that wouldn't survive
      // being folded into `done`.
      const osc133Timeout = Duration(seconds: 120);
      // Subscribe BEFORE sending so we don't race the next D marker.
      final pending = pipe.awaitNextCommand(
        timeout: osc133Timeout,
        isCancelled: isCancelled,
      );
      _executeOnTab(tab)(wrapped);
      final result = await pending;
      if (result != null) {
        stdout.writeln(
          '[capture] osc133 done cmd=${_logQuote(cmd)} '
          'exit=${result.exitCode} bytes=${result.output.length}',
        );
        return result;
      }
      // `awaitNextCommand` returns null for BOTH cancel and timeout — disambiguate
      // by re-polling the cancellation closure.  Cancel: short-circuit.
      if (isCancelled != null && isCancelled()) {
        stdout.writeln('[capture] osc133 cancelled');
        return null;
      }
      // Otherwise we timed out.  Without this recovery block we used to silently
      // leave the hung command running in the shell — the next agent step would
      // then race its late output and corrupt the next capture.  Mirror the
      // echo-fallback's behaviour: send Ctrl-C, give the shell a short grace
      // period to flush a D marker, then surface a synthetic error envelope.
      stdout.writeln(
        '[capture] osc133 timeout after ${osc133Timeout.inSeconds}s '
        '— sending Ctrl-C to abort stuck command',
      );
      _sendRawToTab(tab, Uint8List.fromList(const [0x03])); // SIGINT
      final recovery = await pipe.awaitNextCommand(
        timeout: const Duration(seconds: 5),
        isCancelled: isCancelled,
      );
      if (recovery != null) {
        stdout.writeln(
          '[capture] osc133 recovered after Ctrl-C exit=${recovery.exitCode}',
        );
        return recovery;
      }
      if (isCancelled != null && isCancelled()) {
        stdout.writeln('[capture] osc133 abort cancelled');
        return null;
      }
      stdout.writeln(
        '[capture] osc133 unrecoverable timeout — giving up; '
        'shell may still be busy',
      );
      return CommandResult(
        output:
            '[ssterm capture] command exceeded '
            '${osc133Timeout.inSeconds}s without producing its OSC 133 ;D '
            'marker; Ctrl-C was sent but the shell did not return to a '
            'prompt. The command may still be running — please switch to '
            'the terminal and clean up before continuing.',
        exitCode: null,
        truncated: false,
      );
    }

    // ── 2. Echo-sentinel fallback ────────────────────────────────────────
    // We drop the `[capture] echo start cmd=… marker=…` line for the
    // same reason as the OSC 133 branch above: the marker is a
    // process-local sentinel never useful to the user, and the cmd is
    // more discoverable on the `done` line next to the exit code.
    // Timeout / cancel branches keep their own log lines.
    final beforeLen = term.buffer.lines.length;
    final marker = '__SSTM_${DateTime.now().microsecondsSinceEpoch}__';

    // Use a parenthesised group + `printf` so the marker is emitted whether the
    // command exits 0 or non-zero; `; echo` would lose the original $? without
    // saving it first.
    _executeOnTab(tab)(
      '$wrapped; __ssterm_ec=\$?; printf "$marker:%s\\n" "\$__ssterm_ec"',
    );

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

    // ── Timeout-recovery: the command never printed its sentinel within
    // `maxWait`.  Before this block, we'd silently return whatever
    // partial output was on screen with `exitCode = null`, leaving the
    // command STILL RUNNING in the shell.  The next agent step would
    // then interleave with its output and corrupt the next capture.
    //
    // Best-effort: send SIGINT (Ctrl-C, byte 0x03) and wait a short
    // grace period for the sentinel.  If that doesn't surface either,
    // bail with a synthetic result so the agent loop can report the
    // problem to the user and stop the loop instead of racing on.
    var timedOut = false;
    if (exitCode == null) {
      timedOut = true;
      stdout.writeln(
        '[capture] echo timeout after ${stopwatch.elapsedMilliseconds}ms '
        '— sending Ctrl-C to abort stuck command',
      );
      _sendRawToTab(tab, Uint8List.fromList(const [0x03])); // SIGINT
      final abortStart = Stopwatch()..start();
      const abortMaxWait = Duration(seconds: 5);
      while (abortStart.elapsed < abortMaxWait) {
        if (isCancelled != null && isCancelled()) {
          stdout.writeln('[capture] echo abort cancelled');
          return null;
        }
        await Future<void>.delayed(pollInterval);
        pollCount++;
        exitCode = extractExit();
        if (exitCode != null) {
          stdout.writeln(
            '[capture] echo recovered after Ctrl-C exit=$exitCode',
          );
          break;
        }
      }
      if (exitCode == null) {
        // Still stuck.  Synthesise an envelope the agent layer can show
        // verbatim and treat as a hard failure — *don't* keep racing
        // against the live shell.
        stdout.writeln(
          '[capture] echo unrecoverable timeout — giving up; '
          'shell may still be busy',
        );
        return CommandResult(
          output:
              '[ssterm capture] command exceeded '
              '${maxWait.inSeconds}s without producing its sentinel; '
              'Ctrl-C was sent but the shell did not return to a prompt. '
              'The command may still be running — please switch to the '
              'terminal and clean up before continuing.',
          exitCode: null,
          truncated: false,
        );
      }
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
    // Single done-line that combines what used to be three records
    // (`echo start`, `echo-marker done`, `returning N lines`).  `cmd=`
    // is now carried here too so the user can pair a `done` with the
    // command it ran without scrolling back.
    stdout.writeln(
      '[capture] echo done cmd=${_logQuote(cmd)} '
      'exit=$exitCode bytes=${cleaned.length} '
      'lines=${buf.length} polls=$pollCount '
      'elapsed=${stopwatch.elapsedMilliseconds}ms truncated=$wasTruncated '
      'timedOut=$timedOut',
    );
    return CommandResult(
      output: cleaned,
      exitCode: exitCode,
      truncated: wasTruncated,
    );
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
