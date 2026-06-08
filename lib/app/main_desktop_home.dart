part of '../main.dart';

// ── Desktop home page (shown when all tabs are closed) ────────────────────────

class _DesktopHomePage extends StatelessWidget {
  const _DesktopHomePage({
    required this.localShells,
    required this.savedHosts,
    required this.configHosts,
    required this.onNewLocal,
    required this.onNewSsh,
    required this.onConnectHost,
    required this.chromeBackground,
  });

  final List<LocalShellOption> localShells;
  final List<SshHost> savedHosts;
  final List<SshHost> configHosts;
  final ValueChanged<LocalShellOption> onNewLocal;
  final VoidCallback onNewSsh;
  final ValueChanged<SshHost> onConnectHost;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    final hasAnything =
        localShells.isNotEmpty || savedHosts.isNotEmpty || configHosts.isNotEmpty;

    return Container(
      color: chromeBackground,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'New Session',
                            style: TextStyle(
                              color: AppColors.maybeOf(context)?.foreground ?? _kFgActive,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.4,
                            ),
                          ),
                        ),
                        _NewConnectionButton(onTap: onNewSsh),
                      ],
                    ),
                  ),

                  if (!Platform.isIOS && localShells.isNotEmpty) ...[
                    _SectionLabel('Local'),
                    const SizedBox(height: 6),
                    PopupSurface(
                      radius: _kCardRadius,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < localShells.length; i++)
                            _ShellRow(
                              shell: localShells[i],
                              isLast: i == localShells.length - 1,
                              onTap: () => onNewLocal(localShells[i]),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  if (savedHosts.isNotEmpty) ...[
                    _SectionLabel('Saved'),
                    const SizedBox(height: 6),
                    PopupSurface(
                      radius: _kCardRadius,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    const SizedBox(height: 20),
                  ],

                  if (configHosts.isNotEmpty) ...[
                    _SectionLabel('SSH Config'),
                    const SizedBox(height: 6),
                    PopupSurface(
                      radius: _kCardRadius,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    const SizedBox(height: 20),
                  ],

                  if (!hasAnything) _EmptyConnections(onNewSsh: onNewSsh),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Local shell row used in _DesktopHomePage
class _ShellRow extends StatelessWidget {
  const _ShellRow({
    required this.shell,
    required this.isLast,
    required this.onTap,
  });

  final LocalShellOption shell;
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
              height: 56,
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
                        color: (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        shell.isWsl ? Icons.laptop_windows : Icons.terminal,
                        size: 17,
                        color: AppColors.maybeOf(context)?.foregroundDim ?? const Color(0xFF6E6E6E),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            shell.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.maybeOf(context)?.foreground ?? _kFgActive,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            shell.executable,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!isLast) const Divider(height: 1, indent: 64, color: _kDivider),
      ],
    );
  }
}
