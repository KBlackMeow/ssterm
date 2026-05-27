part of 'main.dart';

// ── Tab bar ───────────────────────────────────────────────────────────────────
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.active,
    required this.backgroundColor,
    required this.tabSelectedColor,
    required this.tabUnselectedColor,
    required this.onSelect,
    required this.onClose,
    required this.onNewLocal,
    required this.localShells,
    required this.onRefreshLocalShells,
    required this.onNewSsh,
    required this.onSettings,
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
    required this.hasSftp,
    required this.sftpVisible,
    required this.onToggleSftp,
    this.transferManager,
    required this.canSplit,
    required this.isSplit,
    this.splitAxis,
    required this.onSplitHorizontal,
    required this.onSplitVertical,
    required this.frostedGlass,
    this.onFrostedGlassChanged,
    this.onInsertCommand,
  });

  final List<_Tab> tabs;
  final int active;
  final Color backgroundColor;
  final Color tabSelectedColor;
  final Color tabUnselectedColor;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final ValueChanged<LocalShellOption> onNewLocal;
  final List<LocalShellOption> localShells;
  final Future<void> Function() onRefreshLocalShells;
  final VoidCallback onNewSsh;
  final VoidCallback onSettings;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<SshHost> onConnectHost;
  final ValueChanged<String>? onInsertCommand;
  final bool hasSftp;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final TransferManager? transferManager;
  final bool canSplit;
  final bool isSplit;
  final Axis? splitAxis;
  final VoidCallback onSplitHorizontal;
  final VoidCallback onSplitVertical;
  final bool frostedGlass;
  final ValueChanged<bool>? onFrostedGlassChanged;

  static const _preferredTabWidth = 160.0;
  static const _minTabWidth = 80.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (tabs.isEmpty) return const SizedBox.shrink();

                const tabGap = 4.0;
                final slotWidth =
                    (constraints.maxWidth - tabGap * (tabs.length - 1)) /
                    tabs.length;
                final tabWidth = slotWidth.clamp(_minTabWidth, _preferredTabWidth);
                final needsScroll =
                    tabWidth <= _minTabWidth &&
                    tabs.length * (_minTabWidth + tabGap) > constraints.maxWidth;

                final chips = [
                  for (var i = 0; i < tabs.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        right: i < tabs.length - 1 ? tabGap : 0,
                      ),
                      child: SizedBox(
                        width: needsScroll ? _minTabWidth : tabWidth,
                        child: _TabChip(
                          tab: tabs[i],
                          isActive: i == active,
                          tabSelectedColor: tabSelectedColor,
                          tabUnselectedColor: tabUnselectedColor,
                          showClose: true,
                          expand: true,
                          onTap: () => onSelect(i),
                          onClose: () => onClose(i),
                        ),
                      ),
                    ),
                ];

                return needsScroll
                    ? SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: chips),
                      )
                    : Row(children: chips);
              },
            ),
          ),
          _PlusMenu(
            onNewLocal: onNewLocal,
            shells: localShells,
            onRefreshLocalShells: onRefreshLocalShells,
            onNewSsh: onNewSsh,
            savedHosts: savedHosts,
            configHosts: configHosts,
            onConnectHost: onConnectHost,
            frostedGlass: frostedGlass,
            onFrostedGlassChanged: onFrostedGlassChanged,
          ),
          CmdPickerButton(
            onInsert: onInsertCommand,
            frostedGlass: frostedGlass,
          ),
          if (hasSftp) ...[
            _SftpButton(sftpVisible: sftpVisible, onToggle: onToggleSftp),
            if (transferManager != null)
              RepaintBoundary(
                child: _TransferButton(
                  manager: transferManager!,
                  frostedGlass: frostedGlass,
                ),
              ),
          ],
          _SplitButton(
            canSplit: canSplit,
            isSplit: isSplit,
            splitAxis: splitAxis,
            onSplitHorizontal: onSplitHorizontal,
            onSplitVertical: onSplitVertical,
            frostedGlass: frostedGlass,
          ),
          GestureDetector(
            onTap: onSettings,
            child: Tooltip(
              message: 'Settings (⌘,)',
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.settings_outlined,
                  size: 15,
                  color: _kFgInactive,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

// ── SFTP toggle button ────────────────────────────────────────────────────────
class _SftpButton extends StatelessWidget {
  const _SftpButton({required this.sftpVisible, required this.onToggle});

  final bool sftpVisible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: sftpVisible ? 'Hide SFTP' : 'Show SFTP',
      child: GestureDetector(
        onTap: onToggle,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(
            Icons.folder_outlined,
            size: 15,
            color: sftpVisible ? const Color(0xFF2472C8) : _kFgInactive,
          ),
        ),
      ),
    );
  }
}

// ── Transfer menu button ──────────────────────────────────────────────────────
class _TransferButton extends StatelessWidget {
  const _TransferButton({
    required this.manager,
    required this.frostedGlass,
  });

  final TransferManager manager;
  final bool frostedGlass;

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showTransferMenu(
      context: context,
      frostedGlass: frostedGlass,
      manager: manager,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (ctx, _) {
        final activeCount = manager.activeCount;
        return Tooltip(
          message: 'Transfers',
          child: GestureDetector(
            onTap: () => _showMenu(ctx),
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.swap_vert, size: 15, color: _kFgInactive),
                  if (activeCount > 0)
                    Positioned(
                      right: -4,
                      top: -3,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2472C8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$activeCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Split button ──────────────────────────────────────────────────────────────
class _SplitButton extends StatelessWidget {
  const _SplitButton({
    required this.canSplit,
    required this.isSplit,
    this.splitAxis,
    required this.onSplitHorizontal,
    required this.onSplitVertical,
    required this.frostedGlass,
  });

  final bool canSplit;
  final bool isSplit;
  final Axis? splitAxis;
  final VoidCallback onSplitHorizontal;
  final VoidCallback onSplitVertical;
  final bool frostedGlass;

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showFrostedMenu<String>(
      context: context,
      frostedGlass: frostedGlass,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'h',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.vertical_split, size: 13, color: _kFgInactive),
              const SizedBox(width: 8),
              Text(
                'Split horizontal',
                style: TextStyle(
                  color: splitAxis == Axis.horizontal
                      ? const Color(0xFF2472C8)
                      : _kFgActive,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'v',
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.splitscreen, size: 13, color: _kFgInactive),
              const SizedBox(width: 8),
              Text(
                'Split vertical',
                style: TextStyle(
                  color: splitAxis == Axis.vertical
                      ? const Color(0xFF2472C8)
                      : _kFgActive,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    ).then((v) {
      if (v == 'h') onSplitHorizontal();
      if (v == 'v') onSplitVertical();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Split',
      child: GestureDetector(
        onTap: canSplit ? () => _showMenu(context) : null,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(
            Icons.splitscreen,
            size: 15,
            color: isSplit
                ? const Color(0xFF2472C8)
                : canSplit
                ? _kFgInactive
                : _kFgInactive.withAlpha(80),
          ),
        ),
      ),
    );
  }
}

// ── Tab chip ──────────────────────────────────────────────────────────────────
class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.tab,
    required this.isActive,
    required this.tabSelectedColor,
    required this.tabUnselectedColor,
    required this.showClose,
    required this.expand,
    required this.onTap,
    required this.onClose,
  });

  final _Tab tab;
  final bool isActive;
  final Color tabSelectedColor;
  final Color tabUnselectedColor;
  final bool showClose;
  final bool expand;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isActive;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isActive
                ? widget.tabSelectedColor
                : widget.tabUnselectedColor,
            borderRadius: BorderRadius.circular(_kTabRadius),
          ),
          child: Row(
            children: [
              Icon(
                widget.tab.icon,
                size: 12,
                color: isActive ? _kFgActive : _kFgInactive,
              ),
              const SizedBox(width: 6),
              if (widget.expand)
                Expanded(
                  child: Text(
                    widget.tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? _kFgActive : _kFgInactive,
                      fontSize: 12,
                      fontWeight:
                          isActive ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                )
              else
                Flexible(
                  child: Text(
                    widget.tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? _kFgActive : _kFgInactive,
                      fontSize: 12,
                      fontWeight:
                          isActive ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                ),
              if (widget.showClose) ...[
                const SizedBox(width: 4),
                _CloseBtn(
                  onTap: widget.onClose,
                  visible: isActive || _hover,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseBtn extends StatefulWidget {
  const _CloseBtn({required this.onTap, required this.visible});

  final VoidCallback onTap;
  final bool visible;

  @override
  State<_CloseBtn> createState() => _CloseBtnState();
}

class _CloseBtnState extends State<_CloseBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFF4A4A4A) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.close,
            size: 11,
            color: widget.visible
                ? (_hover ? _kFgActive : _kFgInactive)
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

// ── Plus menu ─────────────────────────────────────────────────────────────────
class _PlusMenu extends StatelessWidget {
  const _PlusMenu({
    required this.onNewLocal,
    required this.shells,
    required this.onRefreshLocalShells,
    required this.onNewSsh,
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
    required this.frostedGlass,
    this.onFrostedGlassChanged,
  });

  static const _frostedToggleValue = '__frosted_glass__';
  static const _refreshShellsValue = '__refresh_shells__';

  final ValueChanged<LocalShellOption> onNewLocal;
  /// Cached list rendered synchronously. Updated by the host via
  /// [onRefreshLocalShells] (background diff; no per-open work).
  final List<LocalShellOption> shells;
  final Future<void> Function() onRefreshLocalShells;
  final VoidCallback onNewSsh;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<SshHost> onConnectHost;
  final bool frostedGlass;
  final ValueChanged<bool>? onFrostedGlassChanged;

  static const _headerStyle = TextStyle(
    color: Color(0xFF6E6E6E),
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );

  PopupMenuItem<String> _sectionHeader(String label) => PopupMenuItem<String>(
    enabled: false,
    height: 28,
    child: Text(label, style: _headerStyle),
  );

  PopupMenuItem<String> _hostItem(SshHost h, String prefix) =>
      PopupMenuItem<String>(
        value: '$prefix:${h.profileKey}',
        height: 36,
        child: Row(
          children: [
            Icon(
              prefix == 'saved'
                  ? Icons.bookmark_outline
                  : Icons.description_outlined,
              size: 13,
              color: _kFgInactive,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    h.alias,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _kFgActive, fontSize: 13),
                  ),
                  Text(
                    h.displayInfo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _kFgInactive, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  PopupMenuItem<String> _shellItem(LocalShellOption shell) => PopupMenuItem(
    value: 'shell:${shell.id}',
    height: 36,
    child: Row(
      children: [
        Icon(
          shell.isWsl ? Icons.laptop_windows : Icons.terminal,
          size: 13,
          color: _kFgInactive,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            shell.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _kFgActive, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    showFrostedMenu<String>(
      context: context,
      frostedGlass: frostedGlass,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
        minWidth: 220,
      ),
      items: [
        if (shells.isNotEmpty) ...[
          _sectionHeader('Shells'),
          for (final shell in shells) _shellItem(shell),
        ],
        PopupMenuItem<String>(
          value: _refreshShellsValue,
          height: 32,
          child: Row(
            children: const [
              Icon(Icons.refresh, size: 13, color: _kFgInactive),
              SizedBox(width: 8),
              Text(
                'Refresh shells',
                style: TextStyle(color: _kFgInactive, fontSize: 12),
              ),
            ],
          ),
        ),
        if (savedHosts.isNotEmpty) ...[
          const PopupMenuDivider(height: 1),
          _sectionHeader('Saved'),
          for (final h in savedHosts) _hostItem(h, 'saved'),
        ],
        if (configHosts.isNotEmpty) ...[
          const PopupMenuDivider(height: 1),
          _sectionHeader('~/.ssh/config'),
          for (final h in configHosts) _hostItem(h, 'config'),
        ],
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: 'new',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.add, size: 13, color: _kFgInactive),
              SizedBox(width: 8),
              Text(
                'New SSH…',
                style: TextStyle(color: _kFgActive, fontSize: 13),
              ),
            ],
          ),
        ),
        if (onFrostedGlassChanged != null) ...[
          const PopupMenuDivider(height: 1),
          PopupMenuItem(
            value: _frostedToggleValue,
            height: 36,
            child: Row(
              children: [
                const Icon(Icons.blur_on, size: 13, color: _kFgInactive),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Frosted glass',
                    style: TextStyle(color: _kFgActive, fontSize: 13),
                  ),
                ),
                if (frostedGlass)
                  const Icon(
                    Icons.check,
                    size: 14,
                    color: Color(0xFF2472C8),
                  ),
              ],
            ),
          ),
        ],
      ],
    ).then((v) {
      if (v == null) return;
      if (v == _frostedToggleValue) {
        onFrostedGlassChanged?.call(!frostedGlass);
        return;
      }
      if (v == _refreshShellsValue) {
        unawaited(onRefreshLocalShells());
        return;
      }
      if (v.startsWith('shell:')) {
        final id = v.substring('shell:'.length);
        for (final shell in shells) {
          if (shell.id == id) {
            onNewLocal(shell);
            return;
          }
        }
        return;
      }
      if (v == 'new') {
        onNewSsh();
        return;
      }
      if (v.startsWith('saved:') || v.startsWith('config:')) {
        final sep = v.indexOf(':');
        final prefix = v.substring(0, sep);
        final key = v.substring(sep + 1);
        final list = prefix == 'saved' ? savedHosts : configHosts;
        for (final h in list) {
          if (h.profileKey == key) {
            onConnectHost(h);
            break;
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showMenu(context),
      child: Tooltip(
        message: 'New tab',
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: const Icon(Icons.add, size: 15, color: _kFgInactive),
        ),
      ),
    );
  }
}

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}
