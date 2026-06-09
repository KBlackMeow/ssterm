// `setState` is `@protected` on the [State] class; calling it from an
// extension method is technically outside an instance member, even though
// `this` is still a [State] subclass at runtime.  Same exemption applies
// here as in `settings_sheet_agent.dart` — the extension is library-scoped
// to part-of `settings_sheet.dart` and only mixed into `_SettingsPageState`.
// ignore_for_file: invalid_use_of_protected_member

part of 'settings_sheet.dart';

// ───────────────────────────────────────────────────────────────────────────
// Safety settings tab — dangerous-command filtering for agent-emitted
// commands.
//
// Surface area kept deliberately small:
//   • One master switch (agent confirmation on/off).
//   • A list of built-in rules with per-rule enable/disable.
//   • A list of user-defined regex patterns with add / edit / delete.
//
// All state lives in [AgentConfig.dangerousPolicy] and round-trips through
// the existing [_agentApply] hook, so every edit immediately reaches
// [CommandSafety.danger] in the agent loop — toggling a switch here takes
// effect on the very next agent command, no app restart required.
//
// User-typed terminal input is NOT gated.  See [DangerousCommandsPolicy]
// for the rationale.
// ───────────────────────────────────────────────────────────────────────────

extension _SafetySettingsExt on _SettingsPageState {
  DangerousCommandsPolicy get _dangerPolicy =>
      _agentConfig.dangerousPolicy;

  /// Mutate-then-apply helper.  Settings UIs are almost always small
  /// deltas on top of the existing policy, and DangerousCommandsPolicy is
  /// mutable, so we hand the caller a writable handle, then push the
  /// (possibly new) object through [_agentApply] which fires the
  /// configured `onAgentChanged` callback.
  void _updatePolicy(void Function(DangerousCommandsPolicy p) mutate) {
    // Copy first so the on-disk + in-memory model see the exact same
    // snapshot — avoids a class of races where the user changes another
    // field mid-rebuild and we accidentally clobber it.
    final next = _dangerPolicy.copyWith();
    mutate(next);
    _agentApply(_agentConfig.copyWith(dangerousPolicy: next));
  }

  TextEditingController _dangerLabelCtrl(CustomDangerPattern p) {
    return _dangerLabelControllers.putIfAbsent(
      p.id,
      () => TextEditingController(text: p.label),
    );
  }

  TextEditingController _dangerPatternCtrl(CustomDangerPattern p) {
    return _dangerPatternControllers.putIfAbsent(
      p.id,
      () => TextEditingController(text: p.pattern),
    );
  }

  void _disposeDangerCtrls(String id) {
    _dangerLabelControllers.remove(id)?.dispose();
    _dangerPatternControllers.remove(id)?.dispose();
  }

  Widget _buildSafetyTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _sectionTitle('Overview'),
        _safetyOverviewBlurb(),
        const SizedBox(height: 16),
        _sectionTitle('Agent Commands'),
        _agentSafetySection(),
        const SizedBox(height: 16),
        _sectionTitle('Built-in Rules'),
        _builtinRulesSection(),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _sectionTitle('Custom Rules')),
            TextButton.icon(
              onPressed: _addCustomDangerRule,
              icon: const Icon(Icons.add, size: 14, color: _kAccent),
              label: const Text(
                'Add',
                style: TextStyle(color: _kAccent, fontSize: 12),
              ),
            ),
          ],
        ),
        _customRulesSection(),
      ],
    );
  }

  Widget _safetyOverviewBlurb() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: const Text(
        "Filters destructive commands the agent tries to run — rm -rf /, "
        'dd to a block device, curl | sh, fork bombs, etc. When a rule '
        'matches, the agent loop pauses and you must confirm before it '
        'runs. Patterns are matched case-insensitively against the full '
        'command line; multi-line scripts are scanned line by line. '
        'Commands you type yourself are not gated.',
        style: TextStyle(color: _kFgMuted, fontSize: 12, height: 1.4),
      ),
    );
  }

  Widget _agentSafetySection() {
    return Container(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: SwitchListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        dense: true,
        title: const Text(
          'Require confirmation for agent commands',
          style: TextStyle(color: _kFg, fontSize: 13),
        ),
        subtitle: const Text(
          'Even in auto-execute mode, a confirmation card appears in the '
          'chat before any matched destructive command runs. Reject sends '
          "the agent feedback so it can choose a safer approach.",
          style: TextStyle(color: _kFgMuted, fontSize: 11, height: 1.3),
        ),
        value: _dangerPolicy.agentConfirmEnabled,
        activeThumbColor: _kAccent,
        onChanged: (v) =>
            _updatePolicy((p) => p.agentConfirmEnabled = v),
      ),
    );
  }

  Widget _builtinRulesSection() {
    final rules = CommandSafety.builtinDangerRules;
    return Container(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rules.length; i++) ...[
            if (i != 0)
              const Divider(height: 1, color: _kDivider),
            _builtinRuleTile(rules[i].id, rules[i].label),
          ],
        ],
      ),
    );
  }

  Widget _builtinRuleTile(String id, String label) {
    final disabled = _dangerPolicy.disabledBuiltins.contains(id);
    return SwitchListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      dense: true,
      title: Text(
        label,
        style: const TextStyle(color: _kFg, fontSize: 13),
      ),
      subtitle: Text(
        id,
        style: const TextStyle(
          color: _kFgMuted,
          fontSize: 11,
          fontFamily: 'JetBrainsMono',
        ),
      ),
      value: !disabled,
      activeThumbColor: _kAccent,
      onChanged: (enabled) => _updatePolicy((p) {
        if (enabled) {
          p.disabledBuiltins.remove(id);
        } else {
          p.disabledBuiltins.add(id);
        }
      }),
    );
  }

  Widget _customRulesSection() {
    final patterns = _dangerPolicy.customPatterns;
    if (patterns.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kDivider),
        ),
        child: const Text(
          'No custom rules. Add one to flag commands the built-in list '
          'misses — e.g. a project-specific destructive script.',
          style: TextStyle(color: _kFgMuted, fontSize: 12, height: 1.4),
        ),
      );
    }
    return Column(
      children: [
        for (final p in patterns) ...[
          _customRuleCard(p),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _customRuleCard(CustomDangerPattern pattern) {
    final labelCtrl = _dangerLabelCtrl(pattern);
    final patternCtrl = _dangerPatternCtrl(pattern);
    // Validate as the user types so the warning shows immediately, but
    // the rule itself remains in the list — a malformed regex is just
    // silently skipped by [CommandSafety.danger], which means the only
    // visible consequence here is the helper text.
    final isValid =
        CommandSafety.isValidDangerRegex(patternCtrl.text);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  pattern.id,
                  style: const TextStyle(
                    color: _kFgMuted,
                    fontSize: 10,
                    fontFamily: 'JetBrainsMono',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Switch(
                value: pattern.enabled,
                activeThumbColor: _kAccent,
                onChanged: (v) => _updatePolicy((_) {
                  pattern.enabled = v;
                }),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: _kFgMuted,
                ),
                tooltip: 'Delete rule',
                onPressed: () => _deleteCustomDangerRule(pattern),
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: const EdgeInsets.all(6),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _agentTextFieldRow(
            label: 'Label',
            controller: labelCtrl,
            onChanged: (v) => _updatePolicy((_) {
              pattern.label = v;
            }),
          ),
          const SizedBox(height: 6),
          _agentTextFieldRow(
            label: 'Regex',
            controller: patternCtrl,
            onChanged: (v) => _updatePolicy((_) {
              pattern.pattern = v;
            }),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 88),
            child: Text(
              isValid
                  ? 'Case-insensitive Dart RegExp. Matched against each '
                      'line of the command.'
                  : 'Invalid regex — rule will be ignored until fixed.',
              style: TextStyle(
                color: isValid
                    ? _kFgMuted
                    : const Color(0xFFFF6E67),
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addCustomDangerRule() {
    // ID is fixed at creation time and is what we key our controllers
    // by — must stay stable for the lifetime of the rule, otherwise the
    // controller map would leak / cursor would jump.
    final id = 'custom_${DateTime.now().microsecondsSinceEpoch}';
    final fresh = CustomDangerPattern(
      id: id,
      label: 'New rule',
      pattern: '',
      enabled: true,
    );
    _updatePolicy((p) => p.customPatterns.add(fresh));
  }

  Future<void> _deleteCustomDangerRule(CustomDangerPattern p) async {
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
                  const Text(
                    'Delete Custom Rule',
                    style: TextStyle(
                      color: _kFg,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Delete "${p.label}"?',
                    style: const TextStyle(color: _kFgMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(color: _kFgMuted),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Color(0xFFFF6E67)),
                        ),
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
    _disposeDangerCtrls(p.id);
    _updatePolicy(
      (policy) =>
          policy.customPatterns.removeWhere((c) => c.id == p.id),
    );
  }
}
