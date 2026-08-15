// ignore_for_file: invalid_use_of_protected_member

part of 'settings_sheet.dart';

extension _ShellIntegrationSettingsExt on _SettingsPageState {
  Future<void> _loadShellIntegrations() async {
    if (_shellIntegrationLoading) return;
    await _shellIntegrationSubscription?.cancel();
    if (!mounted) return;
    setState(() {
      _shellIntegrationLoading = true;
      _shellIntegrationTargets = const [];
    });
    _shellIntegrationSubscription =
        ShellIntegrationManager.discoverIncrementally().listen(
          (target) {
            if (!mounted) return;
            setState(() {
              final targets = [..._shellIntegrationTargets];
              final index = targets.indexWhere((item) => item.id == target.id);
              if (index < 0) {
                targets.add(target);
              } else {
                targets[index] = target;
              }
              _shellIntegrationTargets = targets;
            });
          },
          onError: (Object error) {
            if (mounted) {
              _showShellIntegrationMessage(
                'Could not inspect all shell profiles: $error',
              );
            }
          },
          onDone: () {
            if (mounted) setState(() => _shellIntegrationLoading = false);
          },
        );
  }

  Widget _buildShellIntegrationTab() {
    return ListView(
      key: const Key('settings-shell-integration-tab'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle('Shell Integration')),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _shellIntegrationLoading
                  ? null
                  : _loadShellIntegrations,
              icon: const Icon(Icons.refresh, color: _kAccent, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Installs a marked, removable profile block that reports the shell '
          'working directory to SSTerm. Shells still start without integration '
          'arguments. Existing profile content is backed up before changes.',
          style: TextStyle(color: _kFgMuted, fontSize: 12, height: 1.45),
        ),
        const SizedBox(height: 14),
        if (_shellIntegrationLoading && _shellIntegrationTargets.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
            ),
          )
        else if (_shellIntegrationTargets.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No supported local shells were found.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _kFgMuted, fontSize: 12),
            ),
          )
        else
          for (final target in _shellIntegrationTargets)
            _buildShellIntegrationTile(target),
      ],
    );
  }

  Widget _buildShellIntegrationTile(ShellIntegrationTarget target) {
    final installed = target.state == ShellIntegrationState.installed;
    final unavailable = target.state == ShellIntegrationState.unavailable;
    final checking = target.state == ShellIntegrationState.checking;
    final damaged = target.state == ShellIntegrationState.damaged;
    final color = switch (target.state) {
      ShellIntegrationState.checking => _kAccent,
      ShellIntegrationState.installed => const Color(0xFF5DD39E),
      ShellIntegrationState.damaged => const Color(0xFFFFC857),
      ShellIntegrationState.unavailable => const Color(0xFFFF6B6B),
      ShellIntegrationState.notInstalled => _kFgMuted,
    };
    final status = switch (target.state) {
      ShellIntegrationState.checking => 'Checking…',
      ShellIntegrationState.installed => 'Installed',
      ShellIntegrationState.damaged => 'Needs repair',
      ShellIntegrationState.unavailable => 'Unavailable',
      ShellIntegrationState.notInstalled => 'Not installed',
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: _kSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: _kDivider),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          leading: Icon(Icons.terminal, size: 18, color: color),
          title: Text(
            target.label,
            style: const TextStyle(color: _kFg, fontSize: 13),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status, style: TextStyle(color: color, fontSize: 11)),
              if (target.profilePath != null)
                Text(
                  target.profilePath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kFgMuted,
                    fontSize: 10,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              if (target.message != null)
                Text(
                  target.message!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _kFgMuted, fontSize: 10),
                ),
            ],
          ),
          trailing: target.kind == ShellIntegrationKind.cmd
              ? const SizedBox.shrink()
              : checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _kAccent,
                  ),
                )
              : TextButton(
                  onPressed: () => unavailable
                      ? _retryShellIntegration(target)
                      : installed
                      ? _uninstallShellIntegration(target)
                      : _installShellIntegration(target),
                  child: Text(
                    unavailable
                        ? 'Retry'
                        : installed
                        ? 'Uninstall'
                        : (damaged ? 'Repair' : 'Install'),
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _installShellIntegration(ShellIntegrationTarget target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Install ${target.label} integration?'),
        content: Text(
          'SSTerm will update ${target.profilePath} and create a '
          '.ssterm-backup copy when the file already exists.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runShellIntegrationChange(
      target,
      ShellIntegrationManager.install,
      'Integration installed. Open a new terminal tab to activate it.',
    );
  }

  Future<void> _retryShellIntegration(ShellIntegrationTarget target) async {
    _replaceShellIntegrationTarget(
      target.copyWith(
        state: ShellIntegrationState.checking,
        message: 'Checking again…',
      ),
    );
    try {
      final updated = await ShellIntegrationManager.retry(target);
      if (mounted) _replaceShellIntegrationTarget(updated);
    } catch (error) {
      if (!mounted) return;
      _replaceShellIntegrationTarget(
        target.copyWith(
          state: ShellIntegrationState.unavailable,
          message: error.toString(),
        ),
      );
    }
  }

  void _replaceShellIntegrationTarget(ShellIntegrationTarget target) {
    if (!mounted) return;
    setState(() {
      final targets = [..._shellIntegrationTargets];
      final index = targets.indexWhere((item) => item.id == target.id);
      if (index < 0) {
        targets.add(target);
      } else {
        targets[index] = target;
      }
      _shellIntegrationTargets = targets;
    });
  }

  Future<void> _uninstallShellIntegration(ShellIntegrationTarget target) async {
    await _runShellIntegrationChange(
      target,
      ShellIntegrationManager.uninstall,
      'Integration removed. Existing terminal tabs are unchanged.',
    );
  }

  Future<void> _runShellIntegrationChange(
    ShellIntegrationTarget target,
    Future<ShellIntegrationTarget> Function(ShellIntegrationTarget) operation,
    String successMessage,
  ) async {
    setState(() => _shellIntegrationLoading = true);
    try {
      final updated = await operation(target);
      if (!mounted) return;
      setState(() {
        final index = _shellIntegrationTargets.indexWhere(
          (item) => item.id == target.id,
        );
        if (index >= 0) {
          _shellIntegrationTargets = [..._shellIntegrationTargets]
            ..[index] = updated;
        }
      });
      _showShellIntegrationMessage(successMessage);
    } catch (error) {
      if (mounted) _showShellIntegrationMessage('Operation failed: $error');
    } finally {
      if (mounted) setState(() => _shellIntegrationLoading = false);
    }
  }

  void _showShellIntegrationMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
