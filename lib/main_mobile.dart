part of 'main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mobile session drawer
// ─────────────────────────────────────────────────────────────────────────────

class _MobileDrawer extends StatelessWidget {
  const _MobileDrawer({
    required this.tabs,
    required this.active,
    required this.savedHosts,
    required this.configHosts,
    required this.backgroundColor,
    required this.onSelect,
    required this.onClose,
    required this.onNewSsh,
    required this.onConnectHost,
    required this.onSettings,
  });

  final List<_Tab> tabs;
  final int active;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final Color backgroundColor;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final VoidCallback onNewSsh;
  final ValueChanged<SshHost> onConnectHost;
  final VoidCallback onSettings;

  static const _sectionStyle = TextStyle(
    color: _kFgInactive,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.9,
  );

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(label.toUpperCase(), style: _sectionStyle),
      );

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: backgroundColor,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: const [
                  Icon(Icons.terminal_rounded, size: 18, color: Color(0xFF2472C8)),
                  SizedBox(width: 8),
                  Text(
                    'SSTerm',
                    style: TextStyle(
                      color: _kFgActive,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 4),
                children: [
                  if (tabs.isNotEmpty) ...[
                    _sectionHeader('Active'),
                    for (var i = 0; i < tabs.length; i++)
                      _MobileSessionTile(
                        tab: tabs[i],
                        isActive: i == active,
                        onTap: () {
                          Navigator.pop(context);
                          onSelect(i);
                        },
                        onClose: () => onClose(i),
                      ),
                  ],

                  if (savedHosts.isNotEmpty) ...[
                    if (tabs.isNotEmpty)
                      const Divider(height: 1, color: Color(0xFF2A2A2A)),
                    _sectionHeader('Saved'),
                    for (final h in savedHosts)
                      _MobileHostTile(
                        host: h,
                        icon: Icons.bookmark_outline,
                        onTap: () {
                          Navigator.pop(context);
                          onConnectHost(h);
                        },
                      ),
                  ],

                  if (configHosts.isNotEmpty) ...[
                    const Divider(height: 1, color: Color(0xFF2A2A2A)),
                    _sectionHeader('SSH Config'),
                    for (final h in configHosts)
                      _MobileHostTile(
                        host: h,
                        icon: Icons.description_outlined,
                        onTap: () {
                          Navigator.pop(context);
                          onConnectHost(h);
                        },
                      ),
                  ],

                  if (tabs.isEmpty && savedHosts.isEmpty && configHosts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 24, 16, 0),
                      child: Text(
                        'No connections yet.\nTap + to get started.',
                        style: TextStyle(color: Color(0xFF4A4A4A), fontSize: 14, height: 1.5),
                      ),
                    ),
                ],
              ),
            ),

            const Divider(height: 1, color: Color(0xFF2A2A2A)),

            ListTile(
              leading: const Icon(Icons.add_rounded, color: Color(0xFF2472C8), size: 22),
              title: const Text(
                'New Connection…',
                style: TextStyle(color: _kFgActive, fontSize: 15),
              ),
              onTap: () {
                Navigator.pop(context);
                onNewSsh();
              },
            ),
            ListTile(
              leading: Icon(Icons.settings_outlined, color: _kFgInactive, size: 22),
              title: const Text(
                'Settings',
                style: TextStyle(color: _kFgActive, fontSize: 15),
              ),
              onTap: () {
                Navigator.pop(context);
                onSettings();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileSessionTile extends StatelessWidget {
  const _MobileSessionTile({
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

    final iconColor = error
        ? const Color(0xFFFF6E67)
        : isActive
            ? const Color(0xFF2472C8)
            : _kFgInactive;

    return ListTile(
      selected: isActive,
      selectedTileColor: const Color(0x142472C8),
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: connecting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFF2472C8),
              ),
            )
          : Icon(
              error ? Icons.error_outline : Icons.terminal_rounded,
              size: 18,
              color: iconColor,
            ),
      title: Text(
        tab.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isActive ? _kFgActive : _kFgInactive,
          fontSize: 14,
          fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
        ),
      ),
      trailing: GestureDetector(
        onTap: onClose,
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.close_rounded, size: 16, color: _kFgInactive),
        ),
      ),
      onTap: onTap,
    );
  }
}

class _MobileHostTile extends StatelessWidget {
  const _MobileHostTile({
    required this.host,
    required this.icon,
    required this.onTap,
  });

  final SshHost host;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 17, color: _kFgInactive),
      title: Text(
        host.alias,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _kFgActive, fontSize: 14),
      ),
      subtitle: Text(
        host.displayInfo,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _kFgInactive, fontSize: 12),
      ),
      onTap: onTap,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mobile bottom navigation bar
// ─────────────────────────────────────────────────────────────────────────────

class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({
    required this.tabs,
    required this.active,
    required this.chromeBackground,
    required this.bottomInset,
    required this.onMenu,
    this.hasSftp = false,
    this.sftpVisible = false,
    this.onToggleSftp,
  });

  final List<_Tab> tabs;
  final int active;
  final Color chromeBackground;
  final double bottomInset;
  final VoidCallback onMenu;
  final bool hasSftp;
  final bool sftpVisible;
  final VoidCallback? onToggleSftp;

  static const _barHeight = 50.0;

  String get _title {
    if (tabs.isEmpty || active >= tabs.length) return 'SSTerm';
    return tabs[active].title;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _barHeight + bottomInset,
      decoration: BoxDecoration(
        color: chromeBackground,
        border: const Border(
          top: BorderSide(color: Color(0xFF2A2A2A), width: 0.5),
        ),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Row(
        children: [
          // Menu + session title (tappable area)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onMenu,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    const Icon(Icons.menu_rounded, color: _kFgActive, size: 22),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _kFgActive,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    if (tabs.length > 1) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0x282472C8),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${tabs.length}',
                          style: const TextStyle(
                            color: Color(0xFF2472C8),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          if (hasSftp)
            GestureDetector(
              onTap: onToggleSftp,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.folder_open_rounded,
                  size: 22,
                  color: sftpVisible ? const Color(0xFF2472C8) : _kFgInactive,
                ),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mobile empty state (no active connections)
// ─────────────────────────────────────────────────────────────────────────────

class _MobileEmptyState extends StatelessWidget {
  const _MobileEmptyState({
    required this.savedHosts,
    required this.configHosts,
    required this.onConnectHost,
    required this.onNewSsh,
  });

  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<SshHost> onConnectHost;
  final VoidCallback onNewSsh;

  static const _labelStyle = TextStyle(
    color: _kFgInactive,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.9,
  );

  @override
  Widget build(BuildContext context) {
    final hasHosts = savedHosts.isNotEmpty || configHosts.isNotEmpty;

    return Container(
      color: const Color(0xFF1A1A1A),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: [
          // New connection button
          GestureDetector(
            onTap: onNewSsh,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF2472C8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'New Connection',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (hasHosts) ...[
            const SizedBox(height: 28),

            if (savedHosts.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text('SAVED HOSTS', style: _labelStyle),
              ),
              _HostList(hosts: savedHosts, icon: Icons.bookmark_outline, onTap: onConnectHost),
            ],

            if (configHosts.isNotEmpty) ...[
              if (savedHosts.isNotEmpty) const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text('SSH CONFIG', style: _labelStyle),
              ),
              _HostList(hosts: configHosts, icon: Icons.description_outlined, onTap: onConnectHost),
            ],
          ] else ...[
            const SizedBox(height: 48),
            const Center(
              child: Text(
                'No saved hosts yet.',
                style: TextStyle(color: Color(0xFF3A3A3A), fontSize: 14),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HostList extends StatelessWidget {
  const _HostList({
    required this.hosts,
    required this.icon,
    required this.onTap,
  });

  final List<SshHost> hosts;
  final IconData icon;
  final ValueChanged<SshHost> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (var i = 0; i < hosts.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, indent: 48, color: Color(0xFF2E2E2E)),
            ListTile(
              leading: Icon(icon, size: 18, color: _kFgInactive),
              title: Text(
                hosts[i].alias,
                style: const TextStyle(color: _kFgActive, fontSize: 15),
              ),
              subtitle: Text(
                hosts[i].displayInfo,
                style: const TextStyle(color: _kFgInactive, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, color: Color(0xFF3A3A3A), size: 18),
              onTap: () => onTap(hosts[i]),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-screen SFTP page (mobile)
// ─────────────────────────────────────────────────────────────────────────────

class _SftpPage extends StatefulWidget {
  const _SftpPage({
    required this.sftp,
    required this.host,
    required this.remotePath,
    required this.transferManager,
  });

  final SftpClient sftp;
  final String host;
  final ValueNotifier<String>? remotePath;
  final TransferManager transferManager;

  @override
  State<_SftpPage> createState() => _SftpPageState();
}

class _SftpPageState extends State<_SftpPage> {
  final _sftpKey = GlobalKey<SftpViewState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      body: Column(
        children: [
          // Header with notch/Dynamic Island safe area
          Container(
            color: const Color(0xFF1C1C1C),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 50,
                child: Row(
                  children: [
                    // Back
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.pop(context),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Color(0xFF2472C8),
                          size: 18,
                        ),
                      ),
                    ),
                    // Title
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Files',
                            style: TextStyle(
                              color: _kFgActive,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                          Text(
                            widget.host,
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
                    // Actions: up, refresh, new folder, upload
                    _SftpHeaderBtn(
                      icon: Icons.arrow_upward_rounded,
                      onTap: () => _sftpKey.currentState?.goUp(),
                    ),
                    _SftpHeaderBtn(
                      icon: Icons.refresh_rounded,
                      onTap: () => _sftpKey.currentState?.refresh(),
                    ),
                    _SftpHeaderBtn(
                      icon: Icons.create_new_folder_outlined,
                      onTap: () => _sftpKey.currentState?.createFolder(),
                    ),
                    _SftpHeaderBtn(
                      icon: Icons.upload_rounded,
                      onTap: () => _sftpKey.currentState?.uploadFile(),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2A2A)),
          // File list — MediaQuery.removePadding prevents ListView from
          // adding a top inset equal to the status bar height (which is
          // already consumed by the header's SafeArea above).
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: SafeArea(
                top: false,
                child: SftpView(
                  key: _sftpKey,
                  sftp: widget.sftp,
                  host: widget.host,
                  remotePath: widget.remotePath,
                  transferManager: widget.transferManager,
                  frostedGlass: false,
                  showToolbar: false,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SftpHeaderBtn extends StatelessWidget {
  const _SftpHeaderBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 50,
        child: Icon(icon, size: 20, color: const Color(0xFF8E8E8E)),
      ),
    );
  }
}
