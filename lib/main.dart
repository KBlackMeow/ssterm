import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:window_manager/window_manager.dart';

import 'dialogs/connect_dialog.dart';
import 'io/output_pipe.dart';
import 'models/app_config.dart';
import 'models/tab_model.dart';
import 'models/saved_hosts_store.dart';
import 'models/ssh_config.dart';
import 'models/ssh_host.dart';
import 'services/host_key_verifier.dart';
import 'services/local_pty_service.dart';
import 'services/local_shell_discovery.dart';
import 'services/local_shell_wrapper.dart';
import 'services/port_forward_service.dart';
import 'services/remote_cwd_parser.dart';
import 'services/remote_home.dart';
import 'services/session_logger.dart';
import 'services/ssh_connection.dart';
import 'services/wallpaper_storage.dart';
import 'utils/fd_limit.dart';
import 'utils/ssh_error_messages.dart';
import 'views/settings/settings_sheet.dart' show SettingsPage;
import 'widgets/cmd_picker_button.dart';
import 'widgets/frosted_glass.dart';
import 'widgets/split_view.dart';
import 'widgets/terminal_surface.dart'
    show TerminalSurface, TerminalContextMenuConfig;
import 'models/transfer_task.dart';
import 'views/ssh_session_view.dart';
import 'widgets/transfer_panel.dart';
import 'widgets/wallpaper_background.dart';

part 'main_local.dart';
part 'main_ssh.dart';
part 'main_chrome.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Must run before the first Pty.start: spawned shells inherit RLIMIT_NOFILE
  // from this process, and macOS's default 256 is too low for plugin-heavy
  // zsh setups.
  raiseFileDescriptorLimit();

  // Custom title bar: hide the OS-drawn caption strip and let the tab bar take
  // its place (Chrome / Edge / Windows Terminal style). On macOS the native
  // traffic-light buttons stay visible; on Windows/Linux we draw our own
  // min/max/close controls inside the tab bar.
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFF1E1E1E),
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const SsTermApp());
}

class SsTermApp extends StatelessWidget {
  const SsTermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSTerm',
      debugShowCheckedModeBanner: false,
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: const TerminalHome(),
    );
  }
}

// Chrome palette — foreground; backgrounds come from [TerminalSettings].
const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);
const _kTabRadius = 6.0;


// ── Tab model ────────────────────────────────────────────────────────────────
typedef _Tab = AppTab;
typedef _TabKind = AppTabKind;

// ── Home ──────────────────────────────────────────────────────────────────────
class TerminalHome extends StatefulWidget {
  const TerminalHome({super.key});

  @override
  State<TerminalHome> createState() => _TerminalHomeState();
}

class _TerminalHomeState extends _TerminalHomeSshMethods {

  @override
  void initState() {
    super.initState();
    _newLocalTab(LocalShellDiscovery.defaultShell(_localShells));
    _loadSshHosts();
    AppConfig.load().then((c) {
      if (!mounted) return;
      setState(() {
        _config = c;
        // Prefer the persisted list (includes WSL distros on Windows) over the
        // boot-time sync discovery. Falls back to the sync result when the
        // config has nothing yet (first launch).
        if (c.cachedShells.isNotEmpty) _localShells = c.cachedShells;
      });
      // Background diff: only setState + save when the discovered list
      // actually differs from what we just restored. This keeps subsequent
      // `+` clicks free of any discovery cost and avoids gratuitous rebuilds
      // of the chrome (which would otherwise thrash the paragraph caches of
      // every open terminal).
      unawaited(_refreshLocalShellsIfChanged());
    });
  }

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

  @override
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

  @override
  void dispose() {
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  bool get _activeTabCanSplit {
    if (_tabs.isEmpty || _active >= _tabs.length) return false;
    final kind = _tabs[_active].kind;
    return kind == _TabKind.local || kind == _TabKind.ssh;
  }

  bool get _activeTabIsSplit =>
      _tabs.isNotEmpty && _active < _tabs.length && _tabs[_active].isSplit;

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
        Expanded(child: _buildBody()),
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

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.comma):
            const _OpenSettingsIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyW):
            const _CloseTabIntent(),
      },
      child: Actions(
        actions: {
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
            onInvoke: (_) {
              _openSettings();
              return null;
            },
          ),
          _CloseTabIntent: CallbackAction<_CloseTabIntent>(
            onInvoke: (_) {
              _closeTab(_active);
              return null;
            },
          ),
        },
        child: _buildChrome(),
      ),
    );
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

  Widget _buildBody() {
    if (_tabs.isEmpty) return const SizedBox.shrink();
    return IndexedStack(
      index: _active,
      sizing: StackFit.expand,
      children: [for (final tab in _tabs) _buildTabBody(tab)],
    );
  }
}

