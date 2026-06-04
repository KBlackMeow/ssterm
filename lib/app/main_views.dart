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
          onNewSsh: () => _showConnectDialog(),
          onSettings: _openSettings,
          savedHosts: _savedHosts,
          configHosts: _configHosts,
          onConnectHost: _connectSavedHost,
          onInsertCommand:
              _tabs.isNotEmpty && _tabs[_active].terminal != null
              ? _insertCommand
              : null,
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
          frostedGlass: _config.sftpFrostedGlass,
          onFrostedGlassChanged: (v) {
            setState(() => _config.sftpFrostedGlass = v);
            _config.save();
          },
        ),
        Expanded(
          child: SafeArea(
            top: false,
            child: _buildBody(),
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
  }

  // ── Mobile layout ──────────────────────────────────────────────────────────

  Widget _buildMobileChrome() {
    final ts = _config.terminal;
    final activeTab =
        _tabs.isNotEmpty && _active < _tabs.length ? _tabs[_active] : null;
    final hasSftp =
        activeTab?.sftp != null && activeTab?.transferManager != null;
    final hasTerminal = activeTab?.terminal != null;

    // Fixed UI chrome color — Connections/Files/Settings never follow terminal theme.
    const uiBackground = Color(0xFF111113);

    return Scaffold(
      backgroundColor: _mobileTabIndex == 1 ? ts.chromeBackground : uiBackground,
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
                        await _showConnectDialog();
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
                        await _showConnectDialog();
                        if (mounted && _tabs.isNotEmpty) {
                          setState(() => _mobileTabIndex = 1);
                        }
                      },
                      onInsertCommand: hasTerminal ? _insertCommand : null,
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
                            frostedGlass: _config.sftpFrostedGlass,
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
                      sftpFrostedGlass: _config.sftpFrostedGlass,
                      onSftpFrostedGlassChanged: (v) {
                        setState(() => _config.sftpFrostedGlass = v);
                        _config.save();
                      },
                      savedHosts: _savedHosts,
                      onSaveHost: (original, updated) =>
                          _saveSavedHost(original, updated),
                      onDeleteHost: _deleteSavedHost,
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
        frostedGlass: _config.sftpFrostedGlass,
        onLayoutChanged: (pos, size) {
          _config.sftpPosition = pos;
          _config.sftpSize = size;
          _config.save();
        },
        child: body,
      );
    }

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
        sftpFrostedGlass: _config.sftpFrostedGlass,
        onSftpFrostedGlassChanged: (v) {
          setState(() => _config.sftpFrostedGlass = v);
          _config.save();
        },
        savedHosts: _savedHosts,
        onSaveHost: (original, updated) => _saveSavedHost(original, updated),
        onDeleteHost: (host) => _deleteSavedHost(host),
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
              style: const TextStyle(
                color: _kFgActive,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'You can switch tabs while waiting.',
              style: TextStyle(color: _kFgInactive, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBody(_Tab tab) {
    final alias = tab.sshProfile?.alias ?? tab.title;
    return Container(
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
                style: const TextStyle(
                  color: _kFgActive,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tab.connectionError ?? 'Connection failed',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _kFgInactive, fontSize: 13),
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
                    onPressed: () => _editAndRetryConnectingTab(tab),
                  ),
                ],
              ),
            ],
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
      frostedGlass: _config.sftpFrostedGlass,
      includeWallpaper: false,
      autofocus: sshPane == 0,
    );

    if (tab.kind == _TabKind.ssh && tab.sftp != null) {
      surface = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _activateSshPaneForSftp(tab, sshPane),
        child: surface,
      );
    }

    return surface;
  }
}
