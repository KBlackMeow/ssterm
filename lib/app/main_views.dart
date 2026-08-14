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

  String? _commandEnvironmentFor(_Tab tab) {
    if (tab.kind != _TabKind.local || tab.localShell == null) return null;
    final shell = tab.localShell!;
    if (shell.isWsl) {
      return 'Linux running in WSL (${shell.displayName}). Commands run inside '
          'the Linux distribution, not Windows cmd.exe or PowerShell. Use '
          'POSIX/Linux commands (for example `ip addr`, not `ipconfig`).';
    }
    if (shell.usePowerShellCwdWrapper) {
      return 'Windows PowerShell (${shell.displayName}). Use PowerShell syntax '
          'and cmdlets; do not use cmd.exe command separators such as `& ver` '
          'as a shell probe. For a blank line use `Write-Output \'\'` or '
          '`[Console]::WriteLine()`; never use bare `echo`.';
    }
    if (shell.id == 'cmd') {
      return 'Windows cmd.exe. Use cmd.exe syntax and built-in commands; do '
          'not use PowerShell cmdlets or POSIX shell syntax.';
    }
    if (shell.id.startsWith('git-bash') ||
        shell.executable.toLowerCase().endsWith('bash.exe')) {
      return 'Git Bash / MSYS POSIX shell. Use POSIX shell syntax and Unix '
          'commands, not cmd.exe or PowerShell syntax.';
    }
    return 'Local shell: ${shell.displayName}. Use this shell\'s native command syntax.';
  }

  FileSystemAdapter _localFileAdapter(_Tab tab, String? Function() cwd) {
    final shell = tab.localShell;
    if (shell?.isWsl == true && shell!.id.startsWith('wsl:')) {
      return WslFileSystemAdapter(
        distribution: shell.id.substring('wsl:'.length),
        cwdProvider: cwd,
      );
    }
    return LocalFileSystemAdapter(
      cwdProvider: cwd,
      pathNormalizer: shell != null && isGitBashShell(shell)
          ? (path) => nativePathForLocalShell(shell, path)
          : null,
    );
  }

  // ── Desktop layout ─────────────────────────────────────────────────────────

  Widget _buildChrome() {
    final ts = _config.terminal;
    final hasWallpaper = ts.hasWallpaper;
    final wallpaperFile = hasWallpaper
        ? WallpaperStorage.resolveFile(ts.wallpaperId)
        : null;

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
              onClose: _requestCloseTab,
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
              agentPanelVisible:
                  _tabs.isNotEmpty &&
                  _active < _tabs.length &&
                  _tabs[_active].agentPanelVisible,
              onToggleAgentPanel: () {
                if (_tabs.isNotEmpty && _active < _tabs.length) {
                  setState(
                    () => _tabs[_active].agentPanelVisible =
                        !_tabs[_active].agentPanelVisible,
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
          backgroundColor: wallpaperFile != null
              ? Colors.transparent
              : ts.chromeBackground,
          body: chrome,
        );
      },
    );
  }

  // ── Mobile layout ──────────────────────────────────────────────────────────

  Widget _buildMobileChrome() {
    final ts = _config.terminal;
    final activeTab = _tabs.isNotEmpty && _active < _tabs.length
        ? _tabs[_active]
        : null;
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
                      agentPanelVisible:
                          hasTerminal && _tabs[_active].agentPanelVisible,
                      onToggleAgentPanel: hasTerminal
                          ? () => setState(
                              () => _tabs[_active].agentPanelVisible =
                                  !_tabs[_active].agentPanelVisible,
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
    if (_tabs.isEmpty) return _buildChromeBackgroundFill();
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
    if (_tabs.isEmpty) return _buildChromeBackgroundFill();
    return IndexedStack(
      index: _active,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < _tabs.length; i++)
          ExcludeFocus(
            excluding: i != _active,
            child: RepaintBoundary(
              key: ObjectKey(_tabs[i]),
              child: _buildTabBody(_tabs[i]),
            ),
          ),
      ],
    );
  }

  Widget _buildChromeBackgroundFill() {
    return ColoredBox(
      color: _config.terminal.chromeBackground,
      child: const SizedBox.expand(),
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
        onLayoutChanged: (pos, size) {
          _config.sftpPosition = pos;
          _config.sftpSize = size;
          _config.save();
        },
        onOpenEditorTab:
            ({required path, required initialContent, required mtime}) =>
                _openEditorTab(
                  sourceTab: tab,
                  path: path,
                  initialContent: initialContent,
                  mtime: mtime,
                ),
        child: body,
      );
    }

    body = AiAssistantOverlay(
      key: ValueKey('agent-${tab.hashCode}'),
      visible: tab.agentPanelVisible,
      onExecuteAsync: (cmd, {isCancelled, onUpdate}) => _recordAgentCommand(
        tab,
        cmd,
        () => _executeAgentCommand(
          tab,
          cmd,
          isCancelled: isCancelled,
          onUpdate: onUpdate,
        ),
      ),
      agentConfig: _config.agent,
      terminalBackground: _config.terminal.chromeBackground,
      terminalLineHeight: _config.terminal.lineHeight,
      fileSystemAdapter: switch (tab.kind) {
        _TabKind.local => _localFileAdapter(tab, () => tab.agentCwd),
        _TabKind.ssh when tab.sftp != null => SftpFileSystemAdapter(
          sftp: tab.sftp,
          label: 'ssh: ${tab.title}',
          cwdProvider: () => tab.agentCwd,
        ),
        _ => null,
      },
      executionEnvironment: _commandEnvironmentFor(tab),
      initialPosition: _config.agentPosition,
      initialSize: _config.agentSize,
      onLayoutChanged: (pos, size) {
        _config.agentPosition = pos;
        _config.agentSize = size;
        _config.save();
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
      _TabKind.editor => FileEditorView(
        key: tab.editorViewKey,
        path: tab.editorPath!,
        sftp: tab.editorSftp!,
        label: tab.editorLabel!,
        initialContent: tab.editorInitialContent ?? '',
        initialMtime: tab.editorMtime,
        dirty: tab.editorDirty,
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
                color:
                    AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive,
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
                    color:
                        AppColors.maybeOf(innerCtx)?.foreground ?? _kFgActive,
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
                    color:
                        AppColors.maybeOf(innerCtx)?.foregroundDim ??
                        _kFgInactive,
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
                      onPressed: () =>
                          _editAndRetryConnectingTab(tab, ctx: innerCtx),
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
      autofocus: sshPane == 0 && _tabs.indexOf(tab) == _active,
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
