part of 'main.dart';

// ─── Design tokens ────────────────────────────────────────────────────────────
const _kCardFill   = Color(0xFF1D1D1F);   // Apple-standard dark surface, truly neutral
const _kCardBorder = Color(0x14FFFFFF);
const _kDivider    = Color(0x0CFFFFFF);
const _kAccent     = Color(0xFF2472C8);
const _kCardRadius = 16.0;
const _kBarRadius  = 28.0;

// ─────────────────────────────────────────────────────────────────────────────
// Connections page  (tab 0 — the app's home screen)
// Lists active sessions + saved hosts; primary entry point for connecting.
// ─────────────────────────────────────────────────────────────────────────────

class _ConnectionsPage extends StatelessWidget {
  const _ConnectionsPage({
    required this.tabs,
    required this.active,
    required this.savedHosts,
    required this.configHosts,
    required this.onSelectSession,
    required this.onCloseSession,
    required this.onNewSsh,
    required this.onConnectHost,
    this.chromeBackground = const Color(0xFF111113),
  });

  final List<_Tab> tabs;
  final int active;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<int> onSelectSession;  // switches to terminal tab
  final ValueChanged<int> onCloseSession;
  final VoidCallback onNewSsh;
  final ValueChanged<SshHost> onConnectHost;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 600;
    final hasAnything =
        tabs.isNotEmpty || savedHosts.isNotEmpty || configHosts.isNotEmpty;

    return Scaffold(
      backgroundColor: chromeBackground,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Large title + new button ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Connections',
                      style: TextStyle(
                        color: _kFgActive,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  _NewConnectionButton(onTap: onNewSsh),
                ],
              ),
            ),

            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: isTablet
                      ? const BoxConstraints(maxWidth: 560)
                      : const BoxConstraints(),
                  child: CustomScrollView(
                    slivers: [
                      // ── Active sessions ──
                      if (tabs.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: _SectionLabel('Active Sessions'),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                            child: _ListCard(
                              children: [
                                for (var i = 0; i < tabs.length; i++)
                                  _ActiveSessionRow(
                                    tab: tabs[i],
                                    isActive: i == active,
                                    isLast: i == tabs.length - 1,
                                    onOpen: () => onSelectSession(i),
                                    onClose: () => onCloseSession(i),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      // ── Saved hosts ──
                      if (savedHosts.isNotEmpty) ...[
                        SliverToBoxAdapter(child: _SectionLabel('Saved')),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                            child: _ListCard(
                              children: [
                                for (var i = 0; i < savedHosts.length; i++)
                                  _HostRow(
                                    host: savedHosts[i],
                                    isLast: i == savedHosts.length - 1,
                                    onTap: () => onConnectHost(savedHosts[i]),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      // ── SSH config hosts ──
                      if (configHosts.isNotEmpty) ...[
                        SliverToBoxAdapter(child: _SectionLabel('SSH Config')),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                            child: _ListCard(
                              children: [
                                for (var i = 0; i < configHosts.length; i++)
                                  _HostRow(
                                    host: configHosts[i],
                                    isLast: i == configHosts.length - 1,
                                    onTap: () => onConnectHost(configHosts[i]),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      // ── Empty state ──
                      if (!hasAnything)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyConnections(onNewSsh: onNewSsh),
                        ),

                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: MediaQuery.of(context).padding.bottom + 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminal page  (tab 1)
// Session tab strip at top + full-screen terminal below.
// ─────────────────────────────────────────────────────────────────────────────

class _TerminalPage extends StatelessWidget {
  const _TerminalPage({
    required this.tabs,
    required this.active,
    required this.onSelectSession,
    required this.onCloseSession,
    required this.onNewSsh,
    required this.onInsertCommand,
    required this.terminalBody,
    this.chromeBackground = const Color(0xFF111113),
  });

  final List<_Tab> tabs;
  final int active;
  final ValueChanged<int> onSelectSession;
  final ValueChanged<int> onCloseSession;
  final VoidCallback onNewSsh;
  final ValueChanged<String>? onInsertCommand;
  final Widget terminalBody;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) {
      return _NoSessionsPlaceholder(chromeBackground: chromeBackground);
    }

    return Column(
      children: [
        // Session tab strip — part of the layout, never overlaid
        _SessionTabStrip(
          tabs: tabs,
          active: active,
          onSelect: onSelectSession,
          onClose: onCloseSession,
          onAdd: onNewSsh,
          onCommands: onInsertCommand != null
              ? (ctx) => _showCommandsSheet(ctx, onInsertCommand!)
              : null,
          chromeBackground: chromeBackground,
        ),
        Expanded(child: terminalBody),
      ],
    );
  }

  static Future<void> _showCommandsSheet(
    BuildContext context,
    ValueChanged<String> onInsert,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommandsSheet(onInsert: onInsert),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Session tab strip — horizontal scrollable tab bar at top of terminal
// ─────────────────────────────────────────────────────────────────────────────

class _SessionTabStrip extends StatelessWidget {
  const _SessionTabStrip({
    required this.tabs,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
    required this.chromeBackground,
    this.onCommands,
  });

  final List<_Tab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onAdd;
  final void Function(BuildContext)? onCommands;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: chromeBackground,
        border: const Border(
          bottom: BorderSide(color: Color(0x18FFFFFF), width: 0.5),
        ),
      ),
      child: Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: tabs.length,
                  itemBuilder: (_, i) => _SessionTab(
                    tab: tabs[i],
                    isActive: i == active,
                    onTap: () => onSelect(i),
                    onClose: () => onClose(i),
                  ),
                ),
              ),
              // Add session
              _StripIconBtn(
                icon: Icons.add_rounded,
                onTap: onAdd,
                tooltip: 'New session',
              ),
              // Commands
              if (onCommands != null)
                Builder(
                  builder: (ctx) => _StripIconBtn(
                    icon: Icons.menu_book_rounded,
                    onTap: () => onCommands!(ctx),
                    tooltip: 'Commands',
                  ),
                ),
              const SizedBox(width: 4),
            ],
          ),
    );
  }
}

class _SessionTab extends StatelessWidget {
  const _SessionTab({
    required this.tab,
    required this.isActive,
    required this.onTap,
    required this.onClose,
  });

  final _Tab tab;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final connecting = tab.kind == _TabKind.sshConnecting;
    final error = tab.kind == _TabKind.sshError;

    final dotColor = error
        ? const Color(0xFFFF6E67)
        : connecting
            ? const Color(0xFFFFD166)
            : const Color(0xFF34C759);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 80, maxWidth: 160),
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0x22FFFFFF)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isActive
              ? Border.all(color: const Color(0x18FFFFFF), width: 0.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Status dot
            connecting
                ? const SizedBox(
                    width: 7,
                    height: 7,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.2,
                      color: Color(0xFFFFD166),
                    ),
                  )
                : Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                tab.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? _kFgActive : _kFgInactive,
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: onClose,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 13,
                  color: isActive
                      ? _kFgInactive
                      : _kFgInactive.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StripIconBtn extends StatelessWidget {
  const _StripIconBtn({
    required this.icon,
    required this.onTap,
    this.tooltip = '',
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 36,
          height: 44,
          child: Icon(
            icon,
            size: 18,
            color: _kFgInactive.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Commands bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _CommandsSheet extends StatefulWidget {
  const _CommandsSheet({required this.onInsert});

  final ValueChanged<String> onInsert;

  @override
  State<_CommandsSheet> createState() => _CommandsSheetState();
}

class _CommandsSheetState extends State<_CommandsSheet> {
  List<Command> _commands = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    CommandsStore.load().then((cmds) {
      if (!mounted) return;
      setState(() {
        _commands = cmds;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    const sheetRadius = BorderRadius.vertical(top: Radius.circular(20));

    Widget content;
    if (_loading) {
      content = const Padding(
        padding: EdgeInsets.all(48),
        child: Center(
          child: CircularProgressIndicator(color: _kAccent, strokeWidth: 2),
        ),
      );
    } else if (_commands.isEmpty) {
      content = Padding(
        padding: const EdgeInsets.all(48),
        child: Center(
          child: Text(
            'No commands saved.\nAdd commands in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _kFgInactive.withValues(alpha: 0.6),
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ),
      );
    } else {
      content = ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPad + 16),
        itemCount: _commands.length,
        itemBuilder: (_, i) {
          final cmd = _commands[i];
          return Column(
            children: [
              if (i > 0)
                const Divider(height: 1, indent: 60, color: _kDivider),
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onInsert(cmd.command);
                  },
                  overlayColor:
                      WidgetStateProperty.all(const Color(0x0AFFFFFF)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: _kAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.code_rounded,
                            size: 16,
                            color: _kAccent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                cmd.name,
                                style: const TextStyle(
                                  color: _kFgActive,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (cmd.description.isNotEmpty)
                                Text(
                                  cmd.description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _kFgInactive,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: const Color(0xFF3A3A3A).withValues(alpha: 0.6),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    return ClipRRect(
      borderRadius: sheetRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.65,
          ),
          decoration: const BoxDecoration(
            color: _kCardFill,
            borderRadius: sheetRadius,
            border: Border(
              top: BorderSide(color: Color(0x28FFFFFF), width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 36,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFF3A3A3A),
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Commands',
                    style: TextStyle(
                      color: _kFgActive,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, color: _kDivider),
              Flexible(child: content),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Files page — glass navigation header + SFTP view
// ─────────────────────────────────────────────────────────────────────────────

class _MobileFilesPage extends StatefulWidget {
  const _MobileFilesPage({
    super.key,
    required this.sftp,
    required this.host,
    required this.remotePath,
    required this.transferManager,
    this.frostedGlass = false,
    this.chromeBackground = const Color(0xFF111113),
  });

  final SftpClient sftp;
  final String host;
  final ValueNotifier<String>? remotePath;
  final TransferManager transferManager;
  final bool frostedGlass;
  final Color chromeBackground;

  @override
  State<_MobileFilesPage> createState() => _MobileFilesPageState();
}

class _MobileFilesPageState extends State<_MobileFilesPage> {
  final _sftpKey = GlobalKey<SftpViewState>();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GlassNavBar(
          title: 'Files',
          subtitle: widget.host,
          chromeBackground: widget.chromeBackground,
          actions: [
            _NavBarBtn(
              icon: Icons.arrow_upward_rounded,
              tooltip: 'Up',
              onTap: () => _sftpKey.currentState?.goUp(),
            ),
            _NavBarBtn(
              icon: Icons.refresh_rounded,
              tooltip: 'Refresh',
              onTap: () => _sftpKey.currentState?.refresh(),
            ),
            _NavBarBtn(
              icon: Icons.create_new_folder_outlined,
              tooltip: 'New folder',
              onTap: () => _sftpKey.currentState?.createFolder(),
            ),
            RepaintBoundary(
              child: _TransferButton(
                manager: widget.transferManager,
                frostedGlass: widget.frostedGlass,
                chromeBackground: widget.chromeBackground,
              ),
            ),
            _NavBarBtn(
              icon: Icons.upload_rounded,
              tooltip: 'Upload',
              onTap: () => _sftpKey.currentState?.uploadFile(),
            ),
          ],
        ),
        Expanded(
          child: SftpView(
            key: _sftpKey,
            sftp: widget.sftp,
            host: widget.host,
            remotePath: widget.remotePath,
            transferManager: widget.transferManager,
            frostedGlass: widget.frostedGlass,
            showToolbar: false,
            chromeBackground: widget.chromeBackground,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings page wrapper
// ─────────────────────────────────────────────────────────────────────────────

class _MobileSettingsPage extends StatelessWidget {
  const _MobileSettingsPage({
    required this.settings,
    required this.onChanged,
    required this.sftpFrostedGlass,
    required this.onSftpFrostedGlassChanged,
    required this.savedHosts,
    required this.onSaveHost,
    required this.onDeleteHost,
    this.chromeBackground = const Color(0xFF111113),
  });

  final TerminalSettings settings;
  final ValueChanged<TerminalSettings> onChanged;
  final bool sftpFrostedGlass;
  final ValueChanged<bool> onSftpFrostedGlassChanged;
  final List<SshHost> savedHosts;
  final void Function(SshHost?, SshHost) onSaveHost;
  final ValueChanged<SshHost> onDeleteHost;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GlassNavBar(
          title: 'Settings',
          chromeBackground: chromeBackground,
        ),
        Expanded(
          child: SettingsPage(
            settings: settings,
            onChanged: onChanged,
            sftpFrostedGlass: sftpFrostedGlass,
            onSftpFrostedGlassChanged: onSftpFrostedGlassChanged,
            savedHosts: savedHosts,
            onSaveHost: onSaveHost,
            onDeleteHost: onDeleteHost,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom tab bar — 4 tabs (Connections, Terminal, Files, Settings)
// ─────────────────────────────────────────────────────────────────────────────

class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({
    required this.activeTabIndex,
    required this.onTabChanged,
    required this.bottomInset,
    required this.sessionCount,
    this.hasSftp = false,
  });

  final int activeTabIndex;
  final ValueChanged<int> onTabChanged;
  final double bottomInset;
  final int sessionCount;
  final bool hasSftp;

  @override
  Widget build(BuildContext context) {
    final items = [
      _BarItem(
        icon: Icons.hub_rounded,
        label: 'Connections',
        active: activeTabIndex == 0,
        badge: sessionCount > 0 ? '$sessionCount' : null,
        onTap: () => onTabChanged(0),
      ),
      _BarItem(
        icon: Icons.terminal_rounded,
        label: 'Terminal',
        active: activeTabIndex == 1,
        onTap: () => onTabChanged(1),
      ),
      _BarItem(
        icon: Icons.folder_rounded,
        label: 'Files',
        active: activeTabIndex == 2,
        disabled: !hasSftp,
        onTap: hasSftp ? () => onTabChanged(2) : null,
      ),
      _BarItem(
        icon: Icons.tune_rounded,
        label: 'Settings',
        active: activeTabIndex == 3,
        onTap: () => onTabChanged(3),
      ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(14, 8, 14, bottomInset + 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF0111113),
          borderRadius: BorderRadius.circular(_kBarRadius),
          border: Border.all(color: const Color(0x20FFFFFF), width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x38000000),
              blurRadius: 20,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: Row(
            children: [
              for (final item in items)
                Expanded(child: _buildBarItem(item)),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _buildBarItem(_BarItem item) {
    final isActive = item.active && !item.disabled;
    final iconColor = item.disabled
        ? _kFgInactive.withValues(alpha: 0.22)
        : isActive
            ? Colors.white
            : _kFgInactive.withValues(alpha: 0.75);
    final textColor = item.disabled
        ? _kFgInactive.withValues(alpha: 0.18)
        : isActive
            ? Colors.white
            : _kFgInactive.withValues(alpha: 0.65);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: item.disabled ? null : item.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF2472C8) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 22,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Icon(item.icon, color: iconColor, size: 20),
                    if (item.badge != null)
                      Positioned(
                        top: -4,
                        right: -10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: isActive
                                ? Colors.white.withValues(alpha: 0.9)
                                : _kAccent,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            item.badge!,
                            style: TextStyle(
                              color: isActive ? _kAccent : Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 10,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable design primitives
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Text(
        label,
        style: const TextStyle(
          color: _kFgInactive,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kCardFill,
        borderRadius: BorderRadius.circular(_kCardRadius),
        border: Border.all(color: _kCardBorder, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

// Active session row — used in Connections page
class _ActiveSessionRow extends StatelessWidget {
  const _ActiveSessionRow({
    required this.tab,
    required this.isActive,
    required this.isLast,
    required this.onOpen,
    required this.onClose,
  });

  final _Tab tab;
  final bool isActive;
  final bool isLast;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final connecting = tab.kind == _TabKind.sshConnecting;
    final error = tab.kind == _TabKind.sshError;

    final dotColor = error
        ? const Color(0xFFFF6E67)
        : connecting
            ? const Color(0xFFFFD166)
            : const Color(0xFF34C759);

    final subtitle = error
        ? 'Connection error'
        : connecting
            ? 'Connecting…'
            : isActive
                ? 'Active'
                : 'Connected';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onOpen,
            overlayColor: WidgetStateProperty.all(const Color(0x0CFFFFFF)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  // Status indicator
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: dotColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: connecting
                        ? Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: dotColor,
                              ),
                            ),
                          )
                        : Icon(
                            error
                                ? Icons.wifi_off_rounded
                                : Icons.terminal_rounded,
                            size: 17,
                            color: dotColor,
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tab.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _kFgActive,
                            fontSize: 15,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: error
                                ? const Color(0xFFFF6E67)
                                : _kFgInactive,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Open in Terminal button
                  _PillButton(
                    label: 'Open',
                    onTap: onOpen,
                  ),
                  const SizedBox(width: 4),
                  // Close
                  GestureDetector(
                    onTap: onClose,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: _kFgInactive.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!isLast)
          const Divider(height: 1, indent: 64, color: _kDivider),
      ],
    );
  }
}

// Saved / config host row
class _HostRow extends StatelessWidget {
  const _HostRow({
    required this.host,
    required this.isLast,
    required this.onTap,
  });

  final SshHost host;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            overlayColor: WidgetStateProperty.all(const Color(0x0CFFFFFF)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0x12FFFFFF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.dns_rounded,
                      size: 17,
                      color: Color(0xFF6E6E6E),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          host.alias,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _kFgActive,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          host.displayInfo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _kFgInactive,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: Color(0xFF3A3A3A),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!isLast)
          const Divider(height: 1, indent: 64, color: _kDivider),
      ],
    );
  }
}

// Small pill button used in session rows
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: _kAccent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _kAccent.withValues(alpha: 0.25),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: _kAccent,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// "New Connection" button in the connections page header
class _NewConnectionButton extends StatelessWidget {
  const _NewConnectionButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _kAccent,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: _kAccent.withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 16, color: Colors.white),
            SizedBox(width: 4),
            Text(
              'New',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Empty state for Connections page
class _EmptyConnections extends StatelessWidget {
  const _EmptyConnections({required this.onNewSsh});

  final VoidCallback onNewSsh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _kAccent.withValues(alpha: 0.2),
                  _kAccent.withValues(alpha: 0.05),
                ],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _kAccent.withValues(alpha: 0.25),
                width: 0.5,
              ),
            ),
            child: const Icon(Icons.terminal_rounded, size: 32, color: _kAccent),
          ),
          const SizedBox(height: 20),
          const Text(
            'No connections yet',
            style: TextStyle(
              color: _kFgActive,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap New to connect to your first server.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _kFgInactive.withValues(alpha: 0.7),
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),
          GestureDetector(
            onTap: onNewSsh,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: _kAccent,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: _kAccent.withValues(alpha: 0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Text(
                'New Connection',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Placeholder shown in Terminal tab when no sessions are open
class _NoSessionsPlaceholder extends StatelessWidget {
  const _NoSessionsPlaceholder({required this.chromeBackground});

  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: chromeBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.terminal_rounded,
                size: 40,
                color: _kFgInactive.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 14),
              Text(
                'No active sessions',
                style: TextStyle(
                  color: _kFgInactive.withValues(alpha: 0.6),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Go to Connections to start a session.',
                style: TextStyle(
                  color: _kFgInactive.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Placeholder for Files tab when no SFTP is available
class _MobilePagePlaceholder extends StatelessWidget {
  const _MobilePagePlaceholder({
    required this.icon,
    required this.message,
    this.chromeBackground = const Color(0xFF111113),
  });

  final IconData icon;
  final String message;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: chromeBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0x0EFFFFFF),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  icon,
                  size: 28,
                  color: _kFgInactive.withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _kFgInactive.withValues(alpha: 0.45),
                  fontSize: 13,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Glass navigation bar — used by Files and Settings pages
// ─────────────────────────────────────────────────────────────────────────────

class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.title,
    required this.chromeBackground,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final Color chromeBackground;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: chromeBackground,
        border: const Border(
          bottom: BorderSide(color: Color(0x18FFFFFF), width: 0.5),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: _kFgActive,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            color: _kFgInactive,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                ...actions,
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBarBtn extends StatelessWidget {
  const _NavBarBtn({
    required this.icon,
    required this.onTap,
    this.tooltip = '',
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          decoration: enabled
              ? BoxDecoration(
                  color: const Color(0x10FFFFFF),
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? _kFgInactive.withValues(alpha: 0.85)
                : const Color(0xFF2A2A2A),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error / connecting state button
// ─────────────────────────────────────────────────────────────────────────────

class _Ios26Button extends StatelessWidget {
  const _Ios26Button({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x18FFFFFF), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: _kFgActive),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: _kFgActive,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Internal data class for bottom bar items
class _BarItem {
  const _BarItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.disabled = false,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool disabled;
  final VoidCallback? onTap;
  final String? badge;
}
