part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Bottom tab bar — 4 tabs (Connections, Terminal, Files, Settings)
// ─────────────────────────────────────────────────────────────────────────────

class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({
    required this.activeTabIndex,
    required this.onTabChanged,
    required this.bottomInset,
    required this.sessionCount,
    required this.terminalBackground,
    this.hasSftp = false,
  });

  final int activeTabIndex;
  final ValueChanged<int> onTabChanged;
  final double bottomInset;
  final int sessionCount;
  final Color terminalBackground;
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
          color: activeTabIndex == 1
              ? Color.alphaBlend(const Color(0x99000000), terminalBackground)
              : const Color(0xF0111113),
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
