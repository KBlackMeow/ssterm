part of '../main.dart';

// ─── Design tokens ────────────────────────────────────────────────────────────
const _kCardFill   = Color(0xFF1D1D1F);
const _kCardBorder = Color(0x14FFFFFF);
const _kDivider    = Color(0x0CFFFFFF);
const _kAccent     = Color(0xFF2472C8);
const _kCardRadius = 16.0;
const _kBarRadius  = 28.0;

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
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (ctx) {
        final screenH = MediaQuery.of(ctx).size.height;
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 360, maxHeight: screenH * 0.55),
              child: _CommandsSheet(onInsert: onInsert),
            ),
          ),
        );
      },
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
                    icon: Icons.code,
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
    Widget content;
    if (_loading) {
      content = const Padding(
        padding: EdgeInsets.all(40),
        child: Center(
          child: CircularProgressIndicator(color: _kAccent, strokeWidth: 2),
        ),
      );
    } else if (_commands.isEmpty) {
      content = Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text(
            'No commands saved.\nAdd commands in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _kFgInactive.withValues(alpha: 0.6),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
      );
    } else {
      final rows = <Widget>[
        for (var i = 0; i < _commands.length; i++) ...[
          if (i > 0)
            const Divider(height: 1, color: _kDivider),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () {
                Navigator.of(context).pop();
                widget.onInsert(_commands[i].command);
              },
              overlayColor:
                  WidgetStateProperty.all(const Color(0x14FFFFFF)),
              child: SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _commands[i].name,
                        style: const TextStyle(
                          color: _kFgActive,
                          fontSize: 13,
                        ),
                      ),
                      if (_commands[i].description.isNotEmpty)
                        Text(
                          _commands[i].description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _kFgInactive,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ];
      content = SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      );
    }

    return PopupSurface(
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Text(
                'Insert command',
                style: TextStyle(
                  color: Color(0xFF6E6E6E),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            const Divider(height: 1, color: _kDivider),
            Flexible(child: content),
          ],
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
