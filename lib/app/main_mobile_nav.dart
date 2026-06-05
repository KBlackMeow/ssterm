part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Bottom tab bar — 4 tabs (Hosts, Terminal, Files, Settings)
// ─────────────────────────────────────────────────────────────────────────────

class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({
    required this.activeTabIndex,
    required this.onTabChanged,
    required this.bottomInset,
    required this.sessionCount,
    required this.terminalBackground,
    required this.tabSelectedColor,
    this.hasSftp = false,
  });

  final int activeTabIndex;
  final ValueChanged<int> onTabChanged;
  final double bottomInset;
  final int sessionCount;
  final Color terminalBackground;
  final Color tabSelectedColor;
  final bool hasSftp;

  @override
  Widget build(BuildContext context) {
    final colors     = AppColors.maybeOf(context);
    final fg         = colors?.foreground    ?? Colors.white;
    final fgDim      = colors?.foregroundDim ?? _kFgInactive;
    // Mirror desktop tab-bar hierarchy: bar = page bg, pill = chromeTabSelected.
    final barBg      = terminalBackground;
    final pillBg     = tabSelectedColor;
    final barBorder  = fg.withValues(alpha: 0.12);
    final pillBorder = fg.withValues(alpha: 0.22);

    final items = [
      _BarItem(
        icon: Icons.computer,
        label: 'Hosts',
        active: activeTabIndex == 0,
        badge: sessionCount > 0 ? '$sessionCount' : null,
        onTap: () => onTabChanged(0),
      ),
      _BarItem(
        icon: Icons.terminal,
        label: 'Terminal',
        active: activeTabIndex == 1,
        onTap: () => onTabChanged(1),
      ),
      _BarItem(
        icon: Icons.folder_outlined,
        label: 'Files',
        active: activeTabIndex == 2,
        disabled: !hasSftp,
        onTap: hasSftp ? () => onTabChanged(2) : null,
      ),
      _BarItem(
        icon: Icons.settings_outlined,
        label: 'Settings',
        active: activeTabIndex == 3,
        onTap: () => onTabChanged(3),
      ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(14, 8, 14, bottomInset + 8),
      child: Container(
        decoration: BoxDecoration(
          color: barBg,
          borderRadius: BorderRadius.circular(_kBarRadius),
          border: Border.all(color: barBorder, width: 0.5),
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tabWidth = constraints.maxWidth / items.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    left: activeTabIndex * tabWidth + 2,
                    top: 0,
                    bottom: 0,
                    width: tabWidth - 4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: pillBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: pillBorder, width: 1),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x30000000),
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (final item in items)
                        Expanded(child: _buildBarItem(item, fg: fg, fgDim: fgDim)),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static Widget _buildBarItem(_BarItem item, {required Color fg, required Color fgDim}) {
    final isActive = item.active && !item.disabled;
    final iconColor = item.disabled
        ? fgDim.withValues(alpha: 0.22)
        : isActive
            ? fg
            : fgDim.withValues(alpha: 0.75);
    final textColor = item.disabled
        ? fgDim.withValues(alpha: 0.18)
        : isActive
            ? fg
            : fgDim.withValues(alpha: 0.65);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: item.disabled ? null : item.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
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
                            color: _kAccent,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            item.badge!,
                            style: const TextStyle(
                              color: Colors.white,
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
    final colors = AppColors.maybeOf(context);
    final fg     = colors?.foreground    ?? _kFgActive;
    final fgDim  = colors?.foregroundDim ?? _kFgInactive;
    final border = (colors?.foreground ?? Colors.white).withValues(alpha: 0.10);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: chromeBackground,
        border: Border(bottom: BorderSide(color: border, width: 0.5)),
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
                        style: TextStyle(
                          color: fg,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: TextStyle(color: fgDim, fontSize: 11),
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
    final colors  = AppColors.maybeOf(context);
    final fg      = colors?.foreground    ?? Colors.white;
    final fgDim   = colors?.foregroundDim ?? _kFgInactive;
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
                  color: fg.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? fgDim.withValues(alpha: 0.85)
                : fg.withValues(alpha: 0.15),
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
    final colors = AppColors.maybeOf(context);
    final fg     = colors?.foreground ?? _kFgActive;
    final bgTint = fg.withValues(alpha: 0.08);
    final border = fg.withValues(alpha: 0.10);
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: bgTint,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w500),
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
