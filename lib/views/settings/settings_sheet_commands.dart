// See `settings_sheet_agent.dart` for the rationale on this ignore — extension
// methods on `_SettingsPageState` need to invoke `State.setState`, which
// counts as outside an instance member for the static analyzer.
// ignore_for_file: invalid_use_of_protected_member

part of 'settings_sheet.dart';

// ───────────────────────────────────────────────────────────────────────────
// Commands settings tab — quick command list, add/edit/delete dialogs.
//
// Extracted from `settings_sheet.dart` as an extension on the (private)
// `_SettingsPageState` so it keeps direct access to the in-memory command
// list and to [_saveCommands].
// ───────────────────────────────────────────────────────────────────────────

extension _CommandsSettingsExt on _SettingsPageState {
  Widget _buildCommandsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle('Quick Commands')),
            TextButton.icon(
              onPressed: _addCommand,
              icon: const Icon(Icons.add, size: 14, color: _kAccent),
              label: const Text('Add', style: TextStyle(color: _kAccent, fontSize: 12)),
            ),
          ],
        ),
        if (_commands.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No commands yet — tap Add to create one',
                style: TextStyle(color: _kFgMuted, fontSize: 13),
              ),
            ),
          )
        else
          for (var i = 0; i < _commands.length; i++)
            _buildCommandTile(i),
      ],
    );
  }

  Widget _buildCommandTile(int index) {
    final cmd = _commands[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _kDivider),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        leading: const Icon(Icons.terminal, color: _kFgMuted, size: 18),
        title: Row(
          children: [
            Flexible(
              child: Text(
                cmd.name,
                style: const TextStyle(color: _kFg, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (cmd.builtIn) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: _kAccent.withAlpha(40),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: _kAccent.withAlpha(100)),
                ),
                child: const Text(
                  'Official',
                  style: TextStyle(
                    color: _kAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          cmd.command,
          style: const TextStyle(
            color: _kFgMuted,
            fontSize: 11,
            fontFamily: 'JetBrainsMono',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: cmd.builtIn
            ? const SizedBox(width: 8)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 15, color: _kFgMuted),
                    onPressed: () => _editCommand(index),
                    tooltip: 'Edit',
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: const EdgeInsets.all(6),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 15, color: _kFgMuted),
                    onPressed: () => _confirmDeleteCommand(index),
                    tooltip: 'Delete',
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: const EdgeInsets.all(6),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _addCommand() async {
    final result = await _showCommandDialog();
    if (result == null) return;
    setState(() => _commands = [..._commands, result]);
    await _saveCommands();
  }

  Future<void> _editCommand(int index) async {
    final result = await _showCommandDialog(existing: _commands[index]);
    if (result == null) return;
    final updated = List<Command>.from(_commands);
    updated[index] = result;
    setState(() => _commands = updated);
    await _saveCommands();
  }

  Future<void> _confirmDeleteCommand(int index) async {
    final cmd = _commands[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: SizedBox(
          width: 320,
          child: PopupSurface(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Delete Command',
                      style: TextStyle(color: _kFg, fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Text('Delete "${cmd.name}"?',
                      style: const TextStyle(color: _kFgMuted, fontSize: 13)),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel', style: TextStyle(color: _kFgMuted)),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Delete',
                            style: TextStyle(color: Color(0xFFFF6E67))),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    final updated = List<Command>.from(_commands)..removeAt(index);
    setState(() => _commands = updated);
    await _saveCommands();
  }

  Future<Command?> _showCommandDialog({Command? existing}) {
    return showDialog<Command>(
      context: context,
      builder: (ctx) => CommandDialog(existing: existing),
    );
  }
}
