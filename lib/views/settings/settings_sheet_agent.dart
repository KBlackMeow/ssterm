// `setState` is `@protected` on the [State] class; calling it from an
// extension method is technically outside an instance member, even though
// `this` is still a [State] subclass at runtime.  The pattern is safe
// because the extension is library-scoped to part-of `settings_sheet.dart`
// and only mixed into `_SettingsPageState`.  Suppress the analyzer noise
// for the file as a whole rather than peppering each call site.
// ignore_for_file: invalid_use_of_protected_member

part of 'settings_sheet.dart';

// ───────────────────────────────────────────────────────────────────────────
// Agent settings tab — providers, models, skills, web search, file write.
//
// Extracted from `settings_sheet.dart` as an extension on the (private)
// `_SettingsPageState` so it keeps direct access to controllers and to the
// settings application helper.  Kept in a part file so private members
// remain library-scoped and there's no need to widen any visibility.
// ───────────────────────────────────────────────────────────────────────────

extension _AgentSettingsExt on _SettingsPageState {
  Widget _buildAgentTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _sectionTitle('Default Provider'),
        _buildDefaultProviderSection(),
        const SizedBox(height: 16),
        _sectionTitle('Display'),
        _buildAgentDisplaySection(),
        const SizedBox(height: 16),
        _sectionTitle('Web Search'),
        _buildWebSearchSection(),
        const SizedBox(height: 16),
        _sectionTitle('File Write'),
        _buildFileWriteSection(),
        const SizedBox(height: 16),
        _sectionTitle('Skills'),
        _buildSkillsSection(),
        const SizedBox(height: 16),
        _sectionTitle('Providers'),
        for (final p in _agentConfig.providers) _buildProviderCard(p),
      ],
    );
  }

  // ── Skills section ─────────────────────────────────────────────────────
  //
  // Lists every skill discovered by [SkillService.init] (asset-bundled,
  // dynamic, AND `~/.ssterm/skills/<id>/SKILL.md`).  Each row toggles
  // whether the LLM is allowed to use the skill this session.
  //
  // The persisted shape is [AgentConfig.enabledSkills] — a whitelist
  // where null means "all enabled".  The UI normalises back to null
  // whenever the user re-enables every skill, so freshly-installed
  // skills auto-show up without an extra click.
  Widget _buildSkillsSection() {
    final skills = SkillService.skills;
    if (skills.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kDivider),
        ),
        child: Text(
          'No skills installed.  Drop a SKILL.md into '
          '${SkillService.userSkillsDirPath}/<id>/ and restart ssterm '
          'to add one.',
          style: const TextStyle(color: _kFgMuted, fontSize: 12, height: 1.4),
        ),
      );
    }

    final whitelist = _agentConfig.enabledSkills;
    final allIds = skills.map((s) => s.id).toSet();
    bool isEnabled(String id) => whitelist == null || whitelist.contains(id);
    final enabledCount = skills.where((s) => isEnabled(s.id)).length;

    return Container(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$enabledCount of ${skills.length} enabled',
                    style: const TextStyle(color: _kFgMuted, fontSize: 11),
                  ),
                ),
                TextButton(
                  onPressed: enabledCount == skills.length
                      ? null
                      : () => _agentApply(
                            _agentConfig.copyWith(resetEnabledSkills: true),
                          ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                  ),
                  child: const Text('Enable all',
                      style: TextStyle(color: _kAccent, fontSize: 11)),
                ),
                TextButton(
                  onPressed: enabledCount == 0
                      ? null
                      : () => _agentApply(
                            _agentConfig.copyWith(enabledSkills: <String>{}),
                          ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                  ),
                  child: const Text('Disable all',
                      style: TextStyle(color: _kFgMuted, fontSize: 11)),
                ),
              ],
            ),
          ),
          for (final skill in skills) _buildSkillRow(skill, isEnabled(skill.id), allIds),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Text(
              'User skills live in ${SkillService.userSkillsDirPath}/<id>/SKILL.md — '
              'they are auto-discovered at startup.',
              style: const TextStyle(color: _kFgMuted, fontSize: 10.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkillRow(Skill skill, bool enabled, Set<String> allIds) {
    final sourceLabel = switch (skill.source) {
      SkillSource.asset => 'built-in',
      SkillSource.bundled => 'dynamic',
      SkillSource.user => 'user',
    };
    return SwitchListTile(
      contentPadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      dense: true,
      value: enabled,
      activeThumbColor: _kAccent,
      title: Row(
        children: [
          Flexible(
            child: Text(
              skill.id,
              style: TextStyle(
                color: enabled ? _kFg : _kFgMuted,
                fontSize: 12.5,
                fontFamily: 'JetBrainsMono',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: _kSurface,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: _kDivider),
            ),
            child: Text(
              sourceLabel,
              style: const TextStyle(
                color: _kFgMuted,
                fontSize: 9,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: Text(
          skill.description,
          style: const TextStyle(color: _kFgMuted, fontSize: 11, height: 1.35),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onChanged: (v) => _toggleSkill(skill.id, v, allIds),
    );
  }

  /// Update [AgentConfig.enabledSkills] after the user toggles a switch.
  ///
  /// The trick: maintaining the "null = all enabled" sentinel.  If we
  /// always wrote the whitelist explicitly, then a SKILL the user
  /// installs LATER would default to disabled (no automatic visibility).
  /// So whenever the resulting set covers every installed skill, we
  /// collapse it back to null via `resetEnabledSkills: true`.
  void _toggleSkill(String id, bool enabled, Set<String> allIds) {
    final current =
        _agentConfig.enabledSkills ?? Set<String>.of(allIds);
    final next = Set<String>.of(current);
    if (enabled) {
      next.add(id);
    } else {
      next.remove(id);
    }
    final isFullSet = next.length == allIds.length && next.containsAll(allIds);
    _agentApply(
      _agentConfig.copyWith(
        enabledSkills: isFullSet ? null : next,
        resetEnabledSkills: isFullSet,
      ),
    );
  }

  Widget _buildAgentDisplaySection() {
    return Container(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        dense: true,
        title: const Text(
          'Render replies as Markdown',
          style: TextStyle(color: _kFg, fontSize: 13),
        ),
        subtitle: const Text(
          'Bold, lists, headings, and code blocks. Re-parses on every streamed '
          'token, so very long replies (20 KB+) may briefly drop frames.',
          style: TextStyle(color: _kFgMuted, fontSize: 11, height: 1.3),
        ),
        value: _agentConfig.markdownEnabled,
        activeThumbColor: _kAccent,
        onChanged: (v) {
          _agentApply(_agentConfig.copyWith(markdownEnabled: v));
        },
      ),
    );
  }

  // ── Web search section ────────────────────────────────────────────────
  Widget _buildWebSearchSection() {
    final enabled = _agentConfig.webSearchEnabled;
    return Container(
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            dense: true,
            title: const Text(
              'Enable web search (Brave)',
              style: TextStyle(color: _kFg, fontSize: 13),
            ),
            subtitle: const Text(
              'Lets the agent search the web via Brave Search. '
              'Get a free API key (2 000 queries/month) at '
              'api-dashboard.search.brave.com.',
              style: TextStyle(color: _kFgMuted, fontSize: 11, height: 1.3),
            ),
            value: enabled,
            activeThumbColor: _kAccent,
            onChanged: (v) =>
                _agentApply(_agentConfig.copyWith(webSearchEnabled: v)),
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _agentTextFieldRow(
                label: 'API Key',
                controller: _braveSearchKeyController,
                obscure: !_braveSearchKeyVisible,
                suffix: IconButton(
                  icon: Icon(
                    _braveSearchKeyVisible
                        ? Icons.visibility_off
                        : Icons.visibility,
                    size: 16,
                    color: _kFgMuted,
                  ),
                  onPressed: () => setState(() {
                    _braveSearchKeyVisible = !_braveSearchKeyVisible;
                  }),
                ),
                onChanged: (v) => ApiKeyStorage.store(
                    AgentConfig.braveSearchKeyId, v.trim()),
              ),
            ),
        ],
      ),
    );
  }

  // ── File write section ────────────────────────────────────────────────
  Widget _buildFileWriteSection() {
    final enabled = _agentConfig.fileWriteEnabled;
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
          'Enable file write',
          style: TextStyle(color: _kFg, fontSize: 13),
        ),
        subtitle: const Text(
          'Lets the agent propose `[WRITE_FILE_BEGIN]` markers. Every '
          'proposed write shows up as a chat card with a diff preview '
          'and requires you to click Apply — auto-execute does NOT '
          'auto-write. Local writes use atomic temp+rename; SSH writes '
          'go through the active SFTP session.',
          style: TextStyle(color: _kFgMuted, fontSize: 11, height: 1.3),
        ),
        value: enabled,
        activeThumbColor: _kAccent,
        onChanged: (v) =>
            _agentApply(_agentConfig.copyWith(fileWriteEnabled: v)),
      ),
    );
  }

  Widget _buildDefaultProviderSection() {
    final enabledProviders =
        _agentConfig.providers.where((p) => p.enabled).toList();
    final currentProvider = _agentConfig.current;
    final allModels = currentProvider?.models ?? <String>[];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _agentConfig.defaultProvider ??
                (enabledProviders.isNotEmpty ? enabledProviders.first.id : null),
            decoration: const InputDecoration(
              labelText: 'Provider',
              labelStyle: TextStyle(color: _kFgMuted, fontSize: 13),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(color: _kFg, fontSize: 13),
            dropdownColor: _kSurface,
            items: _agentConfig.providers.map((p) {
              return DropdownMenuItem(value: p.id, child: Text(p.displayName));
            }).toList(),
            onChanged: (v) {
              if (v == null) return;
              _agentApply(_agentConfig.copyWith(defaultProvider: v));
            },
          ),
          if (currentProvider != null) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _agentConfig.defaultModel != null &&
                      allModels.contains(_agentConfig.defaultModel)
                  ? _agentConfig.defaultModel
                  : null,
              decoration: const InputDecoration(
                labelText: 'Default Model',
                labelStyle: TextStyle(color: _kFgMuted, fontSize: 13),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(color: _kFg, fontSize: 13),
              dropdownColor: _kSurface,
              hint: Text(
                allModels.isNotEmpty ? allModels.first : 'No models',
                style: const TextStyle(color: _kFgMuted, fontSize: 13),
              ),
              items: allModels.map((m) {
                return DropdownMenuItem(value: m, child: Text(m));
              }).toList(),
              onChanged: (v) {
                if (v == null) return;
                _agentApply(_agentConfig.copyWith(defaultModel: v));
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProviderCard(ProviderConfig provider) {
    final idx = _agentConfig.providers.indexOf(provider);
    final fgColor = provider.enabled ? _kFg : _kFgMuted;
    final apiKeyCtrl = _apiKeyControllers[provider.id]!;
    final baseUrlCtrl = _baseUrlControllers[provider.id]!;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: provider.enabled ? _kAccent.withValues(alpha: 0.3) : _kDivider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_providerIcon(provider.id), size: 16, color: _kAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  provider.displayName,
                  style: TextStyle(
                    color: fgColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: provider.enabled,
                onChanged: (v) {
                  final next = _agentConfig.copyWith(
                    providers: List.of(_agentConfig.providers)
                      ..[idx] = provider.copyWith(enabled: v),
                  );
                  _agentApply(next);
                },
                activeThumbColor: _kAccent,
              ),
            ],
          ),
          if (provider.enabled) ...[
            const SizedBox(height: 10),
            // Local providers (Ollama et al.) have no auth wall — show a
            // gentle hint instead of an inert API-key textbox the user
            // would otherwise fill in for nothing.  See
            // `ProviderConfig.requiresApiKey`.
            if (provider.requiresApiKey)
              _agentTextFieldRow(
                label: 'API Key',
                controller: apiKeyCtrl,
                obscure: !(_apiKeyVisible[provider.id] ?? false),
                suffix: IconButton(
                  icon: Icon(
                    (_apiKeyVisible[provider.id] ?? false)
                        ? Icons.visibility_off
                        : Icons.visibility,
                    size: 16,
                    color: _kFgMuted,
                  ),
                  onPressed: () {
                    setState(() {
                      _apiKeyVisible[provider.id] =
                          !(_apiKeyVisible[provider.id] ?? false);
                    });
                  },
                ),
                onChanged: (v) => ApiKeyStorage.store(provider.id, v),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.lock_open, size: 14, color: _kFgMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'No API key required (local provider). '
                        'Set Base URL to point at your daemon.',
                        style: const TextStyle(
                          color: _kFgMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            _agentTextFieldRow(
              label: 'Base URL',
              controller: baseUrlCtrl,
              onChanged: (v) {
                final next = _agentConfig.copyWith(
                  providers: List.of(_agentConfig.providers)
                    ..[idx] = provider.copyWith(baseUrl: v),
                );
                _agentApply(next);
              },
            ),
            const SizedBox(height: 8),
            _buildModelSection(provider, idx),
          ],
        ],
      ),
    );
  }

  Widget _agentTextFieldRow({
    required String label,
    required TextEditingController controller,
    bool obscure = false,
    Widget? suffix,
    ValueChanged<String>? onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: _kFgMuted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller,
            obscureText: obscure,
            style: const TextStyle(color: _kFg, fontSize: 13),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF161820),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: _kDivider),
              ),
              suffixIcon: suffix,
              isDense: true,
            ),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildModelSection(ProviderConfig provider, int idx) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 80,
          child: Text(
            'Models',
            style: TextStyle(color: _kFgMuted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final m in provider.models)
                _modelChip(m, provider, idx),
              _addModelChip(provider, idx),
            ],
          ),
        ),
      ],
    );
  }

  Widget _modelChip(String model, ProviderConfig provider, int idx) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF161820),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _kDivider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            model,
            style: const TextStyle(color: _kFg, fontSize: 11),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              final nextModels = List<String>.of(provider.models)..remove(model);
              final nextDefault = _agentConfig.defaultModel == model
                  ? null
                  : _agentConfig.defaultModel;
              final next = _agentConfig.copyWith(
                defaultModel: nextDefault,
                providers: List.of(_agentConfig.providers)
                  ..[idx] = provider.copyWith(models: nextModels),
              );
              _agentApply(next);
            },
            child: Icon(Icons.close, size: 12, color: _kFgMuted),
          ),
        ],
      ),
    );
  }

  Widget _addModelChip(ProviderConfig provider, int idx) {
    return GestureDetector(
      onTap: () => _showAddModelDialog(provider, idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: _kAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _kAccent.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 11, color: _kAccent),
            const SizedBox(width: 2),
            Text(
              'Add',
              style: TextStyle(color: _kAccent, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddModelDialog(ProviderConfig provider, int idx) async {
    _modelAddController.clear();
    final name = await showDialog<String>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: _kSurface,
          title: const Text('Add Model', style: TextStyle(color: _kFg, fontSize: 14)),
          content: TextField(
            controller: _modelAddController,
            autofocus: true,
            style: const TextStyle(color: _kFg, fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'e.g. gpt-4-turbo',
              hintStyle: TextStyle(color: _kFgMuted, fontSize: 13),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: _kFgMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, _modelAddController.text.trim()),
              child: const Text('Add', style: TextStyle(color: _kAccent)),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;

    final nextModels = List<String>.of(provider.models)..add(name);
    final next = _agentConfig.copyWith(
      providers: List.of(_agentConfig.providers)
        ..[idx] = provider.copyWith(models: nextModels),
    );
    _agentApply(next);
  }
}

/// Provider-glyph picker for the Agent tab's "Providers" header — kept
/// as a top-level helper because extension methods cannot be `static`.
IconData _providerIcon(String id) {
  switch (id) {
    case 'chatgpt':
      return Icons.psychology;
    case 'claude':
      return Icons.auto_awesome;
    case 'gemini':
      return Icons.flutter_dash;
    case 'deepseek':
      return Icons.explore;
    case 'ollama':
      // The llama silhouette doesn't exist in Material; `pets` is the
      // closest "this is the local animal-themed model runner" cue and
      // matches Ollama's mascot well enough at icon size.
      return Icons.pets;
    default:
      return Icons.smart_toy;
  }
}
