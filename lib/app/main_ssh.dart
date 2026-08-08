part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SSH business logic — connection lifecycle, SFTP, split-pane SSH sessions,
// reconnect, keepalive, port forwarding, and saved-host management.
// ─────────────────────────────────────────────────────────────────────────────

abstract class _TerminalHomeSshMethods extends _TerminalHomeLocalMethods {
  CommandExecutionHistory get commandHistory;

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
      holdOutputUntilRelease: true,
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
    tab.agent2Cwd = remotePath.value;
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
      holdOutputUntilRelease: true,
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
      if (!mounted) return;
      _syncPaneAfterShown(tab, pane: 1);
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
      if (!mounted) return;
      _syncPaneAfterShown(tab, pane: 1);
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
        holdOutputUntilRelease: true,
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
      _scheduleSyncPaneAfterShown(tab, pane: 0);
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
      if (oldSession != null) safeSshTeardown(() => oldSession.close());
      if (oldClient != null) safeSshTeardown(() => oldClient.close());
      if (oldJump != null) safeSshTeardown(() => oldJump.close());

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
      tab.clearDeadSshTransport();
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
    removed.prepareForRemoval();
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
    // Three frames: (1) rebuild without the closed tab, (2) surviving tab
    // syncAfterShown / requestKeyboard, (3) native PTY teardown.  Windows
    // TextInput and ClosePseudoConsole both need the UI thread unblocked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          removed.dispose();
        });
      });
    });
  }

  /// Opens a new editor tab for a file read from [sourceTab]'s SFTP
  /// panel. Inserted and activated the same way `_newLocalTab` inserts a
  /// fresh local tab (append + activate) — see `main_local.dart`.
  void _openEditorTab({
    required _Tab sourceTab,
    required String path,
    required String initialContent,
    required DateTime? mtime,
  }) {
    final sftp = sourceTab.sftp;
    if (sftp == null) return; // source tab's SFTP session isn't live
    setState(() {
      _tabs.add(
        _Tab.editor(
          path: path,
          sftp: sftp,
          label: 'ssh: ${sourceTab.title}',
          mtime: mtime,
          initialContent: initialContent,
        ),
      );
      _active = _tabs.length - 1;
    });
    _activateTab(_active);
  }

  /// Gate in front of [_closeTab] for tabs that may have unsaved
  /// changes. Every non-editor tab, and every editor tab that ISN'T
  /// dirty, behaves exactly like the old direct `onClose: _closeTab`
  /// wiring — this only adds a confirmation step for the one new case.
  Future<void> _requestCloseTab(int i) async {
    if (i < 0 || i >= _tabs.length) return;
    final tab = _tabs[i];
    if (tab.kind != _TabKind.editor || !tab.editorDirty.value) {
      _closeTab(i);
      return;
    }

    final colors = AppColors.maybeOf(context);
    final decision = await showDialog<_UnsavedChangesDecision>(
      context: context,
      builder: (ctx) => Theme(
        data: Theme.of(
          context,
        ).copyWith(extensions: colors != null ? {colors} : null),
        child: const _UnsavedChangesDialog(),
      ),
    );
    if (!mounted ||
        decision == null ||
        decision == _UnsavedChangesDecision.cancel) {
      return;
    }
    if (decision == _UnsavedChangesDecision.discard) {
      _closeTab(i);
      return;
    }
    // decision == save
    final saved = await tab.editorViewKey.currentState?.save() ?? false;
    if (!mounted || !saved) return;
    _closeTab(i);
  }

  void _selectTab(int i) {
    if (i == _active) return;
    final prev = _active;
    _tabs[prev].terminalViewKey.currentState?.releaseInput();
    _tabs[prev].splitViewKey.currentState?.releaseInput();
    setState(() => _active = i);
    _activateTab(i);
  }

  @override
  void _activateTab(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i < 0 || i >= _tabs.length) return;
      for (var t = 0; t < _tabs.length; t++) {
        if (t == i) continue;
        _tabs[t].terminalViewKey.currentState?.releaseInput();
        _tabs[t].splitViewKey.currentState?.releaseInput();
      }
      _syncPaneAfterShown(_tabs[i], pane: 0);
      if (_tabs[i].isSplit) {
        _syncPaneAfterShown(_tabs[i], pane: 1);
      }
    });
  }

  void _syncAllTerminals() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final tab in _tabs) {
        _syncPaneAfterShown(tab, pane: 0);
        if (tab.isSplit) {
          _syncPaneAfterShown(tab, pane: 1);
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
      // Strip a trailing newline so we never send two Enters (which would
      // run the command and then submit an empty line, polluting prompt /
      // OSC 133 boundaries).  The command always needs ONE trailing Enter
      // to actually execute; we add it ourselves below.
      //
      // That Enter MUST be `\r` (CR), not `\n` (LF) — this is what a real
      // keypress sends (see xterm's own default keytab: `Enter-NewLine :
      // "\r"`). A bare LF happens to also work on POSIX ptys (canonical
      // line discipline treats NL as end-of-line), which is why this went
      // unnoticed there, but native Windows console input translation
      // (ConPTY, backing local PowerShell/CMD tabs) only synthesizes an
      // Enter/VK_RETURN key event from CR — a bare LF is just inserted as
      // literal input, leaving the command sitting unexecuted until a real
      // keypress supplies the missing CR.
      while (cmd.endsWith('\n') || cmd.endsWith('\r')) {
        cmd = cmd.substring(0, cmd.length - 1);
      }
      final data = utf8.encode('$cmd\r');
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

  /// Which sentinel-fallback syntax to speak for [shell]. `null` (SSH tabs,
  /// or before local shell discovery resolves) defaults to POSIX, matching
  /// today's behavior. Git Bash/WSL fall through to POSIX too — they're
  /// real bash-compatible shells, so the existing `sh`-flavored sentinel
  /// already works there.
  CommandSentinelDialect _sentinelDialectFor(LocalShellOption? shell) {
    if (shell == null) return CommandSentinelDialect.posix;
    if (shell.id == 'cmd') return CommandSentinelDialect.cmd;
    if (shell.usePowerShellWrapper) return CommandSentinelDialect.powershell;
    return CommandSentinelDialect.posix;
  }

  CommandExecutionTarget? _activeCommandTarget(_Tab tab) {
    final isSplitPane = tab.isSplit && tab.activeSshPane == 1;
    final terminal = isSplitPane ? tab.splitTerminal : tab.terminal;
    if (terminal == null) return null;

    return CommandExecutionTarget(
      terminal: terminal,
      outputPipe: isSplitPane ? tab.splitPipe : tab.pipe,
      sendCommand: _executeOnTab(tab),
      sendRaw: (bytes) => _sendRawToTab(tab, bytes),
      sentinelDialect: _sentinelDialectFor(tab.localShell),
      shellExecutable: tab.localShell?.executable,
    );
  }

  Future<CommandResult?> _executeAndCapture(
    _Tab tab,
    String command, {
    bool Function()? isCancelled,
  }) {
    final target = _activeCommandTarget(tab);
    if (target == null) return Future.value(null);
    return TerminalCommandExecutor(
      log: stdout.writeln,
    ).execute(target, command, isCancelled: isCancelled);
  }

  Future<CommandResult?> _executeAgent2Command(
    _Tab tab,
    String command, {
    bool Function()? isCancelled,
  }) {
    if (tab.kind != _TabKind.local || tab.localShell == null) {
      return Future.value(
        CommandResult(
          output:
              '[ssterm background] Agent2 remote execution is not wired yet.',
          exitCode: null,
        ),
      );
    }
    return const BackgroundCommandExecutor().executeLocal(
      BackgroundCommandTarget.local(
        shell: tab.localShell!,
        cwd: tab.agent2Cwd ?? '/',
        platform: BackgroundCommandTarget.hostPlatform,
      ),
      command,
      isCancelled: isCancelled,
    );
  }

  Future<CommandResult?> _recordAgentCommand(
    _Tab tab,
    String agentId,
    String command,
    Future<CommandResult?> Function() execute,
  ) async {
    final result = await execute();
    await commandHistory.append(
      CommandExecutionRecord(
        timestamp: DateTime.now(),
        agentId: agentId,
        target: tab.kind == _TabKind.ssh ? 'ssh' : 'local',
        cwd: agentId == 'agent2'
            ? tab.agent2Cwd
            : (tab.kind == _TabKind.ssh
                  ? tab.remotePath?.value
                  : tab.localPath?.value),
        command: command,
        exitCode: result?.exitCode,
        truncated: result?.truncated ?? false,
        output: result?.output ?? '',
        cancelled: result == null,
      ),
    );
    return result;
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

enum _UnsavedChangesDecision { save, discard, cancel }

class _UnsavedChangesDialog extends StatelessWidget {
  const _UnsavedChangesDialog();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final fill = colors?.popup ?? FrostedGlassStyle.menuFillFrosted;
    final fg = colors?.foreground ?? const Color(0xFFD4D4D4);
    final fgDim = colors?.foregroundDim ?? const Color(0xFF8E8E8E);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 380,
        child: PopupSurface(
          color: fill,
          backdropBlur: 20,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Unsaved changes',
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'This file has unsaved changes. Save before closing?',
                  style: TextStyle(color: fgDim, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _UnsavedChangesDecision.cancel,
                      ),
                      child: Text('Cancel', style: TextStyle(color: fgDim)),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _UnsavedChangesDecision.discard,
                      ),
                      child: const Text(
                        "Don't Save",
                        style: TextStyle(color: Color(0xFFFF6E67)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, _UnsavedChangesDecision.save),
                      child: const Text(
                        'Save',
                        style: TextStyle(color: Color(0xFF2472C8)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
