part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// View layer — all Widget-building methods.
//
// Sits between the business-logic layers (_TerminalHomeLocalMethods,
// _TerminalHomeSshMethods) and the thin lifecycle class (_TerminalHomeState).
// Desktop and mobile layout builders live here alongside the shared tab-body
// builders so that main.dart's State class only handles initState/dispose/build.
// ─────────────────────────────────────────────────────────────────────────────

abstract class _TerminalHomeViewMethods extends _TerminalHomeSshMethods {

  // ── Helpers ────────────────────────────────────────────────────────────────

  bool get _activeTabCanSplit {
    if (_tabs.isEmpty || _active >= _tabs.length) return false;
    final kind = _tabs[_active].kind;
    return kind == _TabKind.local || kind == _TabKind.ssh;
  }

  bool get _activeTabIsSplit =>
      _tabs.isNotEmpty && _active < _tabs.length && _tabs[_active].isSplit;

  // ── Desktop layout ─────────────────────────────────────────────────────────

  Widget _buildChrome() {
    final ts = _config.terminal;
    final hasWallpaper = ts.hasWallpaper;
    final wallpaperFile =
        hasWallpaper ? WallpaperStorage.resolveFile(ts.wallpaperId) : null;

    return Builder(
      builder: (innerCtx) {
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
              onNewSsh: () => _showConnectDialog(ctx: innerCtx),
              onSettings: _openSettings,
              savedHosts: _savedHosts,
              configHosts: _configHosts,
              onConnectHost: _connectSavedHost,
              onInsertCommand:
                  _tabs.isNotEmpty && _tabs[_active].terminal != null
                  ? _insertCommand
                  : null,
              aiPanelVisible:
                  _tabs.isNotEmpty &&
                  _active < _tabs.length &&
                  _tabs[_active].aiPanelVisible,
              onToggleAiPanel: () {
                if (_tabs.isNotEmpty && _active < _tabs.length) {
                  setState(
                    () => _tabs[_active].aiPanelVisible =
                        !_tabs[_active].aiPanelVisible,
                  );
                }
              },
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
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: _tabs.isEmpty
                    ? _DesktopHomePage(
                        localShells: _localShells,
                        savedHosts: _savedHosts,
                        configHosts: _configHosts,
                        onNewLocal: _newLocalTab,
                        onNewSsh: () => _showConnectDialog(ctx: innerCtx),
                        onConnectHost: _connectSavedHost,
                        chromeBackground: ts.chromeBackground,
                      )
                    : _buildBody(),
              ),
            ),
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
      },
    );
  }

  // ── Mobile layout ──────────────────────────────────────────────────────────

  Widget _buildMobileChrome() {
    final ts = _config.terminal;
    final activeTab =
        _tabs.isNotEmpty && _active < _tabs.length ? _tabs[_active] : null;
    final hasSftp =
        activeTab?.sftp != null && activeTab?.transferManager != null;
    final hasTerminal = activeTab?.terminal != null;

    // All tabs follow the terminal theme background.
    final uiBackground = ts.chromeBackground;

    return Scaffold(
      backgroundColor: uiBackground,
      body: Builder(
        builder: (ctx) {
          final vp = MediaQuery.of(ctx).viewPadding;

          return Column(
            children: [
              SizedBox(height: vp.top),
              Expanded(
                child: IndexedStack(
                  index: _mobileTabIndex,
                  sizing: StackFit.expand,
                  children: [
                    // 0: Connections — primary hub
                    _ConnectionsPage(
                      tabs: _tabs,
                      active: _active,
                      savedHosts: _savedHosts,
                      configHosts: _configHosts,
                      onSelectSession: (i) {
                        _selectTab(i);
                        setState(() => _mobileTabIndex = 1);
                      },
                      onCloseSession: _closeTab,
                      onNewSsh: () async {
                        await _showConnectDialog(ctx: ctx);
                        if (mounted && _tabs.isNotEmpty) {
                          setState(() => _mobileTabIndex = 1);
                        }
                      },
                      onConnectHost: (h) {
                        _connectSavedHost(h);
                        setState(() => _mobileTabIndex = 1);
                      },
                      chromeBackground: uiBackground,
                    ),
                    // 1: Terminal — session tab strip + full-screen terminal
                    _TerminalPage(
                      tabs: _tabs,
                      active: _active,
                      onSelectSession: _selectTab,
                      onCloseSession: _closeTab,
                      onNewSsh: () async {
                        await _showConnectDialog(ctx: ctx);
                        if (mounted && _tabs.isNotEmpty) {
                          setState(() => _mobileTabIndex = 1);
                        }
                      },
                      onInsertCommand: hasTerminal ? _insertCommand : null,
                      // Mirror the desktop _TabBar wiring so mobile and
                      // chrome stay in sync — without this the AI panel
                      // could be opened only on desktop.
                      aiPanelVisible: hasTerminal &&
                          _tabs[_active].aiPanelVisible,
                      onToggleAiPanel: hasTerminal
                          ? () => setState(
                                () => _tabs[_active].aiPanelVisible =
                                    !_tabs[_active].aiPanelVisible,
                              )
                          : null,
                      terminalBody: _buildTerminalArea(),
                      chromeBackground: ts.chromeBackground,
                    ),
                    // 2: Files (SFTP)
                    hasSftp
                        ? _MobileFilesPage(
                            key: ValueKey(activeTab!.sftp),
                            sftp: activeTab.sftp!,
                            host: activeTab.title,
                            remotePath: activeTab.remotePath,
                            transferManager: activeTab.transferManager!,
                            chromeBackground: uiBackground,
                          )
                        : _MobilePagePlaceholder(
                            icon: Icons.folder_rounded,
                            message:
                                'Connect to an SSH server with SFTP\nto browse files.',
                            chromeBackground: uiBackground,
                          ),
                    // 3: Settings
                    _MobileSettingsPage(
                      settings: _config.terminal,
                      onChanged: (next) {
                        setState(() => _config.terminal = next);
                        _config.save();
                        _syncAllTerminals();
                      },
                      savedHosts: _savedHosts,
                      onSaveHost: (original, updated) =>
                          _saveSavedHost(original, updated),
                      onDeleteHost: _deleteSavedHost,
                      agent: _config.agent,
                      onAgentChanged: (next) {
                        setState(() => _config.agent = next);
                        _config.save();
                      },
                      chromeBackground: uiBackground,
                    ),
                    ],
                  ),
              ),
              _MobileBottomBar(
                activeTabIndex: _mobileTabIndex,
                onTabChanged: (i) => setState(() => _mobileTabIndex = i),
                bottomInset: vp.bottom,
                sessionCount: _tabs.length,
                hasSftp: hasSftp,
                terminalBackground: ts.chromeBackground,
                tabSelectedColor: ts.chromeTabSelected,
              ),
            ],
          );
        },
      ),
    );
  }

  // Returns the terminal body widget (used inside _TerminalPage).
  Widget _buildTerminalArea() {
    if (_tabs.isEmpty) return const SizedBox.expand();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (_active < _tabs.length) {
          _tabs[_active].terminalViewKey.currentState?.requestKeyboard();
        }
      },
      child: _buildBody(),
    );
  }

  // ── Shared tab-body builders ───────────────────────────────────────────────

  Widget _buildBody() {
    if (_tabs.isEmpty) return const SizedBox.expand();
    return IndexedStack(
      index: _active,
      sizing: StackFit.expand,
      children: [for (final tab in _tabs) _buildTabBody(tab)],
    );
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

    // Wrap JUST the terminal pane (and any SplitView around it) in an
    // AbsorbPointer driven by `tab.terminalLocked`.  This MUST happen
    // BEFORE the SshSessionView wrap below — SshSessionView stacks the
    // SFTP floating overlay on top of `body`, and the lock should NOT
    // apply to that overlay (SFTP runs on its own SSH channel and stays
    // usable while the agent works).  Locking up here, around the
    // terminal only, was the fix for SFTP buttons going dead whenever
    // the agent auto-executed a command.
    body = ValueListenableBuilder<bool>(
      valueListenable: tab.terminalLocked,
      builder: (_, locked, child) =>
          AbsorbPointer(absorbing: locked, child: child),
      child: body,
    );

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
        onLayoutChanged: (pos, size) {
          _config.sftpPosition = pos;
          _config.sftpSize = size;
          _config.save();
        },
        child: body,
      );
    }

    body = AiAssistantOverlay(
      visible: tab.aiPanelVisible,
      onInsert: tab.terminal != null ? (cmd) => tab.terminal!.paste(cmd) : null,
      onExecute: tab.terminal != null ? _executeOnTab(tab) : null,
      onExecuteAsync: tab.terminal != null
          ? (String cmd, {isCancelled}) => _executeAndCapture(tab, cmd, isCancelled: isCancelled)
          : null,
      agentConfig: _config.agent,
      onGetShellIntegrationActive:
          tab.terminal != null ? () => _activePaneHasShellIntegration(tab) : null,
      // Pass the terminal pane's background through so AI-reply code
      // blocks render on the SAME color as the terminal next to them
      // (via a Theme override that swaps `colorScheme.onInverseSurface`
      // — see `_buildMarkdown` in ai_assistant_panel.dart).
      terminalBackground: _config.terminal.chromeBackground,
      // ...and the line-height too, so the AI chat reads at the same
      // density as the terminal — defaults to 1.2 but the user can tune
      // it from Settings → Terminal → Line height.
      terminalLineHeight: _config.terminal.lineHeight,
      // Route the agent's auto-execute lock through the per-tab notifier
      // so the AbsorbPointer above wraps only the terminal — leaving the
      // SFTP overlay buttons (which we Stack on top in SshSessionView)
      // fully clickable while the agent runs commands.
      onTerminalLockChanged: (locked) => tab.terminalLocked.value = locked,
      // Filesystem adapter for the agent's `[WRITE_FILE_BEGIN]` tool.
      // Picked per active-tab kind:
      //   • LOCAL → dart:io writer (atomic temp+rename on the host).
      //   • SSH with a live SFTP channel → SFTP writer (atomic
      //     temp+rename over the same session that runs the user's
      //     terminal commands).
      //   • SSH still connecting / SSH error / Settings tab → null;
      //     the agent panel surfaces a "filesystem not available"
      //     envelope to the model when it tries to write.
      fileSystemAdapter: switch (tab.kind) {
        _TabKind.local => const LocalFileSystemAdapter(),
        _TabKind.ssh when tab.sftp != null =>
          SftpFileSystemAdapter(sftp: tab.sftp, label: 'ssh: ${tab.title}'),
        _ => null,
      },
      child: body,
    );

    return body;
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
      _TabKind.sshConnecting => _buildConnectingBody(tab),
      _TabKind.sshError => _buildErrorBody(tab),
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
        agent: _config.agent,
        onAgentChanged: (next) {
          setState(() => _config.agent = next);
          _config.save();
        },
      ),
    };
  }

  Widget _buildConnectingBody(_Tab tab) {
    final alias = tab.sshProfile?.alias ?? tab.title;
    return Container(
      color: _config.terminal.chromeBackground,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Connecting to $alias',
              style: TextStyle(
                color: AppColors.maybeOf(context)?.foreground ?? _kFgActive,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'You can switch tabs while waiting.',
              style: TextStyle(
                color: AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBody(_Tab tab) {
    final alias = tab.sshProfile?.alias ?? tab.title;
    return Builder(
      builder: (innerCtx) => Container(
      color: _config.terminal.chromeBackground,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6E67).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFF6E67).withValues(alpha: 0.25),
                    width: 0.5,
                  ),
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 26,
                  color: Color(0xFFFF6E67),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                alias,
                style: TextStyle(
                  color: AppColors.maybeOf(innerCtx)?.foreground ?? _kFgActive,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tab.connectionError ?? 'Connection failed',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.maybeOf(innerCtx)?.foregroundDim ?? _kFgInactive,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Ios26Button(
                    label: 'Retry',
                    icon: Icons.refresh_rounded,
                    onPressed: () => _retryConnectingTab(tab),
                  ),
                  const SizedBox(width: 10),
                  _Ios26Button(
                    label: 'Edit…',
                    icon: Icons.edit_outlined,
                    onPressed: () => _editAndRetryConnectingTab(tab, ctx: innerCtx),
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

  // ── Terminal surface builder ───────────────────────────────────────────────

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
      includeWallpaper: false,
      autofocus: sshPane == 0,
    );

    if (tab.isSplit) {
      surface = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (tab.activeSshPane != sshPane) {
            tab.activeSshPane = sshPane;
            if (tab.sftp != null) tab.syncRemotePathToActivePane();
          }
        },
        child: surface,
      );
    }

    return surface;
  }
}
