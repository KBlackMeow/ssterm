part of 'main.dart';

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
    return Scaffold(
      backgroundColor: ts.chromeBackground,
      drawer: _MobileDrawer(
        tabs: _tabs,
        active: _active,
        savedHosts: _savedHosts,
        configHosts: _configHosts,
        backgroundColor: ts.chromeBackground,
        onSelect: _selectTab,
        onClose: _closeTab,
        onNewSsh: () => unawaited(_showConnectDialog()),
        onConnectHost: _connectSavedHost,
        onSettings: _openSettings,
      ),
      body: Builder(
        builder: (ctx) {
          final vp = MediaQuery.of(ctx).viewPadding;
          return Column(
            children: [
              SizedBox(height: vp.top),
              Expanded(
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: _tabs.isEmpty
                      ? _MobileEmptyState(
                          savedHosts: _savedHosts,
                          configHosts: _configHosts,
                          onConnectHost: _connectSavedHost,
                          onNewSsh: () => unawaited(_showConnectDialog()),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () {
                            if (_active < _tabs.length) {
                              _tabs[_active].terminalViewKey.currentState
                                  ?.requestKeyboard();
                            }
                          },
                          child: _buildBody(),
                        ),
                ),
              ),
              _MobileBottomBar(
                tabs: _tabs,
                active: _active,
                chromeBackground: ts.chromeBackground,
                bottomInset: vp.bottom,
                onMenu: () => Scaffold.of(ctx).openDrawer(),
                hasSftp: _tabs.isNotEmpty &&
                    _active < _tabs.length &&
                    _tabs[_active].sftp != null,
                sftpVisible: false,
                onToggleSftp: () {
                  if (_tabs.isNotEmpty && _active < _tabs.length) {
                    final tab = _tabs[_active];
                    if (tab.sftp == null || tab.transferManager == null) return;
                    Navigator.push(
                      ctx,
                      MaterialPageRoute<void>(
                        builder: (_) => _SftpPage(
                          sftp: tab.sftp!,
                          host: tab.title,
                          remotePath: tab.remotePath,
                          transferManager: tab.transferManager!,
                        ),
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      ),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              color: Color(0xFF2472C8),
              strokeWidth: 2,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Connecting to $alias…',
            style: const TextStyle(color: _kFgInactive, fontSize: 13),
          ),
          const SizedBox(height: 6),
          const Text(
            'You can switch to other tabs while waiting.',
            style: TextStyle(color: Color(0xFF6E6E6E), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBody(_Tab tab) {
    final alias = tab.sshProfile?.alias ?? tab.title;
    return Container(
      color: _config.terminal.chromeBackground,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 36,
              color: Color(0xFFFF6E67),
            ),
            const SizedBox(height: 12),
            Text(
              alias,
              style: const TextStyle(
                color: _kFgActive,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                tab.connectionError ?? 'Connection failed',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _kFgInactive, fontSize: 12),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _retryConnectingTab(tab),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Retry'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kFgActive,
                    side: const BorderSide(color: Color(0xFF3A3A3A)),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _editAndRetryConnectingTab(tab),
                  icon: const Icon(Icons.edit, size: 14),
                  label: const Text('Edit…'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kFgActive,
                    side: const BorderSide(color: Color(0xFF3A3A3A)),
                  ),
                ),
              ],
            ),
          ],
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
