part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Hosts page  (tab 0 — the app's home screen)
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
  final ValueChanged<int> onSelectSession;
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
                      'Hosts',
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final bottomPad =
                          MediaQuery.of(context).padding.bottom + 20;
                      return SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: IntrinsicHeight(
                            child: Column(
                              mainAxisAlignment: hasAnything
                                  ? MainAxisAlignment.center
                                  : MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // ── Active sessions ──
                                if (tabs.isNotEmpty) ...[
                                  _SectionLabel('Active Sessions'),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 6, 16, 20),
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
                                ],

                                // ── Saved hosts ──
                                if (savedHosts.isNotEmpty) ...[
                                  _SectionLabel('Saved'),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 6, 16, 20),
                                    child: _ListCard(
                                      children: [
                                        for (var i = 0;
                                            i < savedHosts.length;
                                            i++)
                                          _HostRow(
                                            host: savedHosts[i],
                                            isLast: i == savedHosts.length - 1,
                                            onTap: () =>
                                                onConnectHost(savedHosts[i]),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],

                                // ── SSH config hosts ──
                                if (configHosts.isNotEmpty) ...[
                                  _SectionLabel('SSH Config'),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 6, 16, 20),
                                    child: _ListCard(
                                      children: [
                                        for (var i = 0;
                                            i < configHosts.length;
                                            i++)
                                          _HostRow(
                                            host: configHosts[i],
                                            isLast:
                                                i == configHosts.length - 1,
                                            onTap: () =>
                                                onConnectHost(configHosts[i]),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],

                                // ── Empty state ──
                                if (!hasAnything)
                                  Expanded(
                                    child: _EmptyConnections(onNewSsh: onNewSsh),
                                  ),

                                SizedBox(height: bottomPad),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
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
            child: SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Status indicator
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: dotColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: connecting
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: dotColor,
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
                        mainAxisAlignment: MainAxisAlignment.center,
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
            child: SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
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
                        mainAxisAlignment: MainAxisAlignment.center,
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
      child: Builder(
        builder: (context) {
          final color = AppColors.maybeOf(context)?.popup ?? _kCardFill;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0x28FFFFFF), width: 1),
              boxShadow: const [
                BoxShadow(color: Color(0x30000000), blurRadius: 4, offset: Offset(0, 2)),
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
          );
        },
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
