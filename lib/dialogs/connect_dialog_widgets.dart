part of 'connect_dialog.dart';

// ─── Section wrapper (collapsible with enable toggle) ────────────────────────
class _Section extends StatefulWidget {
  const _Section({
    required this.title,
    required this.enabled,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final Widget child;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_Section old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !old.enabled) _expanded = true;
    if (!widget.enabled && old.enabled) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            onTap: widget.enabled
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Switch(
                    value: widget.enabled,
                    onChanged: widget.onToggle,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    activeThumbColor: _kAccent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(color: _kFg, fontSize: 12),
                    ),
                  ),
                  if (widget.enabled)
                    Icon(
                      _expanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 16,
                      color: _kLabel,
                    ),
                ],
              ),
            ),
          ),
          if (widget.enabled && _expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

// ─── Port forwarding section ─────────────────────────────────────────────────
class _ForwardSection extends StatefulWidget {
  const _ForwardSection({
    required this.rules,
    required this.onChanged,
  });

  final List<PortForwardRule> rules;
  final VoidCallback onChanged;

  @override
  State<_ForwardSection> createState() => _ForwardSectionState();
}

class _ForwardSectionState extends State<_ForwardSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final count = widget.rules.length;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.swap_horiz,
                    size: 14,
                    color: _kLabel,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      count == 0
                          ? 'Port forwarding'
                          : 'Port forwarding ($count rules)',
                      style: const TextStyle(color: _kFg, fontSize: 12),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: _kLabel,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _buildRuleList(),
            ),
        ],
      ),
    );
  }

  Widget _buildRuleList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.rules.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No rules',
              style: TextStyle(color: _kLabel, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          )
        else
          for (var i = 0; i < widget.rules.length; i++)
            _RuleRow(
              rule: widget.rules[i],
              onDelete: () {
                setState(() => widget.rules.removeAt(i));
                widget.onChanged();
              },
              onToggle: (v) {
                setState(() {
                  widget.rules[i] = widget.rules[i].copyWith(enabled: v);
                });
                widget.onChanged();
              },
            ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _addRule,
          icon: const Icon(Icons.add, size: 13),
          label: const Text('Add rule', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kLabel,
            side: const BorderSide(color: _kBorder),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }

  void _addRule() async {
    final rule = await showDialog<PortForwardRule>(
      context: context,
      builder: (ctx) => const _AddRuleDialog(),
    );
    if (rule != null) {
      setState(() => widget.rules.add(rule));
      widget.onChanged();
    }
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.rule,
    required this.onDelete,
    required this.onToggle,
  });

  final PortForwardRule rule;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Switch(
            value: rule.enabled,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            activeThumbColor: _kAccent,
          ),
          Expanded(
            child: Text(
              rule.label,
              style: TextStyle(
                color: rule.enabled ? _kFg : _kLabel,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            color: _kLabel,
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}

class _AddRuleDialog extends StatefulWidget {
  const _AddRuleDialog();

  @override
  State<_AddRuleDialog> createState() => _AddRuleDialogState();
}

class _AddRuleDialogState extends State<_AddRuleDialog> {
  ForwardType _type = ForwardType.local;
  final _localPortCtrl = TextEditingController();
  final _remoteHostCtrl = TextEditingController();
  final _remotePortCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _localPortCtrl.dispose();
    _remoteHostCtrl.dispose();
    _remotePortCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final lp = int.tryParse(_localPortCtrl.text.trim()) ?? 0;
    if (lp < 1 || lp > 65535) {
      setState(() => _error = 'Invalid local port');
      return;
    }
    if (_type == ForwardType.local) {
      if (_remoteHostCtrl.text.trim().isEmpty) {
        setState(() => _error = 'Enter remote host');
        return;
      }
      final rp = int.tryParse(_remotePortCtrl.text.trim()) ?? 0;
      if (rp < 1 || rp > 65535) {
        setState(() => _error = 'Invalid remote port');
        return;
      }
    }
    if (_type == ForwardType.remote) {
      final rp = int.tryParse(_remotePortCtrl.text.trim()) ?? 0;
      if (rp < 1 || rp > 65535) {
        setState(() => _error = 'Invalid server port');
        return;
      }
    }

    Navigator.of(context).pop(
      PortForwardRule(
        type: _type,
        localPort: lp,
        remoteHost: _remoteHostCtrl.text.trim(),
        remotePort: int.tryParse(_remotePortCtrl.text.trim()) ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _kBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: 360,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Add Forward Rule',
                style: TextStyle(color: _kTitle, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<ForwardType>(
                // ignore: deprecated_member_use
                value: _type,
                dropdownColor: _kBg,
                style: const TextStyle(color: _kFg, fontSize: 13),
                decoration: _inputDecoration('Type'),
                items: const [
                  DropdownMenuItem(
                    value: ForwardType.local,
                    child: Text('L — Local forward',
                        overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: ForwardType.remote,
                    child: Text('R — Remote forward',
                        overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: ForwardType.dynamic_,
                    child: Text('D — Dynamic SOCKS5',
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
                onChanged: (v) => setState(() => _type = v!),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  switch (_type) {
                    ForwardType.local =>
                      'localhost:local-port  →  server  →  remote-host:port',
                    ForwardType.remote =>
                      'server:port  →  SSH tunnel  →  localhost:local-port',
                    ForwardType.dynamic_ =>
                      'SOCKS5 proxy, all traffic routed via server',
                  },
                  style: const TextStyle(
                      color: Color(0xFF6E6E6E), fontSize: 11),
                ),
              ),
              const SizedBox(height: 6),
              _Field(
                label: _type == ForwardType.dynamic_
                    ? 'Local SOCKS5 port'
                    : 'Local port',
                ctrl: _localPortCtrl,
                inputType: TextInputType.number,
              ),
              if (_type == ForwardType.local) ...[
                const SizedBox(height: 10),
                _Field(
                  label: 'Remote host',
                  ctrl: _remoteHostCtrl,
                  hint: 'e.g. localhost or db.internal',
                ),
                const SizedBox(height: 10),
                _Field(
                  label: 'Remote port',
                  ctrl: _remotePortCtrl,
                  inputType: TextInputType.number,
                ),
              ],
              if (_type == ForwardType.remote) ...[
                const SizedBox(height: 10),
                _Field(
                  label: 'Server listen port',
                  ctrl: _remotePortCtrl,
                  inputType: TextInputType.number,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: _kError, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel', style: TextStyle(color: _kLabel)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _confirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAccent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Advanced section ─────────────────────────────────────────────────────────
class _AdvancedSection extends StatefulWidget {
  const _AdvancedSection({
    required this.keepaliveInterval,
    required this.autoReconnect,
    required this.sessionLog,
    required this.onKeepaliveChanged,
    required this.onAutoReconnectChanged,
    required this.onSessionLogChanged,
  });

  final int keepaliveInterval;
  final bool autoReconnect;
  final bool sessionLog;
  final ValueChanged<int> onKeepaliveChanged;
  final ValueChanged<bool> onAutoReconnectChanged;
  final ValueChanged<bool> onSessionLogChanged;

  @override
  State<_AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<_AdvancedSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.tune, size: 14, color: _kLabel),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Advanced',
                      style: TextStyle(color: _kFg, fontSize: 12),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: _kLabel,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Keepalive interval',
                          style: TextStyle(color: _kLabel, fontSize: 12),
                        ),
                      ),
                      DropdownButton<int>(
                        value: widget.keepaliveInterval,
                        dropdownColor: _kBg,
                        style: const TextStyle(color: _kFg, fontSize: 12),
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('Disabled')),
                          DropdownMenuItem(value: 15, child: Text('15 s')),
                          DropdownMenuItem(value: 30, child: Text('30 s')),
                          DropdownMenuItem(value: 60, child: Text('60 s')),
                        ],
                        onChanged: (v) => widget.onKeepaliveChanged(v ?? 0),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Auto-reconnect',
                          style: TextStyle(color: _kLabel, fontSize: 12),
                        ),
                      ),
                      Switch(
                        value: widget.autoReconnect,
                        onChanged: widget.onAutoReconnectChanged,
                        activeThumbColor: _kAccent,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Session log',
                          style: TextStyle(color: _kLabel, fontSize: 12),
                        ),
                      ),
                      Switch(
                        value: widget.sessionLog,
                        onChanged: widget.onSessionLogChanged,
                        activeThumbColor: _kAccent,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                  if (widget.sessionLog)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Saved to ~/.ssterm/logs/',
                        style: const TextStyle(
                          color: _kLabel,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Shared input widgets ────────────────────────────────────────────────────
InputDecoration _inputDecoration(String label) => InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _kLabel, fontSize: 11),
      filled: true,
      fillColor: _kField,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: _kBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: _kBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: _kFocus),
      ),
    );

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.ctrl,
    this.hint,
    this.obscure = false,
    this.inputType,
  });

  final String label;
  final TextEditingController ctrl;
  final String? hint;
  final bool obscure;
  final TextInputType? inputType;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _kLabel, fontSize: 11)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          keyboardType: inputType,
          style: const TextStyle(color: _kFg, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF4A4A4A), fontSize: 12),
            filled: true,
            fillColor: _kField,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: _kBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: _kBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: _kFocus),
            ),
          ),
        ),
      ],
    );
  }
}
