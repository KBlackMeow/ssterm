part of 'main.dart';

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

  Future<void> _showConnectDialog({SshHost? initialHost}) async {
    final profile = await showConnectDialog(
      context,
      initialHost: initialHost,
      backgroundColor: _config.terminal.chromeBackground,
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

  Future<void> _editAndRetryConnectingTab(_Tab tab) async {
    final profile = tab.sshProfile;
    if (profile == null) return;
    final updated = await showConnectDialog(
      context,
      initialHost: profile,
      backgroundColor: _config.terminal.chromeBackground,
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
