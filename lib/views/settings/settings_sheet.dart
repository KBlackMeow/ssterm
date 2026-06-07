import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:xterm/xterm.dart';

import '../../dialogs/connect_dialog.dart' show showEditHostDialog;
import '../../services/api_key_storage.dart';
import '../../widgets/frosted_glass.dart';
import '../../models/agent_config.dart';
import '../../models/command.dart';
import '../../models/commands_store.dart';
import '../../models/ssh_host.dart';
import '../../models/terminal_settings.dart';
import '../../models/terminal_theme_presets.dart';
import '../../services/image_file_picker.dart';
import '../../services/wallpaper_storage.dart';
import '../../widgets/terminal_preview.dart';
import '../../widgets/wallpaper_background.dart';
import 'settings_dialogs.dart';

const _kSheetBg = Color(0xFF111113);
const _kDivider = Color(0xFF252525);
const _kSurface = Color(0xFF1C1C20);  // dropdown / button backgrounds
const _kFg = Color(0xFFD4D4D4);
const _kFgMuted = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.savedHosts = const [],
    this.onSaveHost,
    this.onDeleteHost,
    this.agent,
    this.onAgentChanged,
  });

  final TerminalSettings settings;
  final ValueChanged<TerminalSettings> onChanged;
  final List<SshHost> savedHosts;
  final void Function(SshHost? original, SshHost updated)? onSaveHost;
  final ValueChanged<SshHost>? onDeleteHost;
  final AgentConfig? agent;
  final ValueChanged<AgentConfig>? onAgentChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  late TerminalSettings _s;
  late AgentConfig _agentConfig;
  late TabController _tabController;
  PackageInfo? _packageInfo;
  List<Command> _commands = const [];

  final _apiKeyControllers = <String, TextEditingController>{};
  final _apiKeyVisible = <String, bool>{};
  final _baseUrlControllers = <String, TextEditingController>{};
  final _modelAddController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _s = widget.settings.copyWith();
    _agentConfig = widget.agent ?? AgentConfig();
    _tabController = TabController(length: 7, vsync: this);
    _loadPackageInfo();
    _loadCommands();
    _initAgentControllers();
  }

  void _initAgentControllers() {
    for (final p in _agentConfig.providers) {
      _apiKeyControllers[p.id] = TextEditingController();
      _baseUrlControllers[p.id] = TextEditingController(text: p.baseUrl ?? '');
      _apiKeyVisible[p.id] = false;
      _loadApiKey(p.id);
    }
  }

  Future<void> _loadApiKey(String id) async {
    final key = await ApiKeyStorage.load(id);
    if (!mounted) return;
    _apiKeyControllers[id]?.text = key ?? '';
  }

  void _agentApply(AgentConfig next) {
    setState(() => _agentConfig = next);
    widget.onAgentChanged?.call(next);
  }

  Future<void> _loadCommands() async {
    final cmds = await CommandsStore.load();
    if (!mounted) return;
    setState(() => _commands = cmds);
  }

  Future<void> _saveCommands() async {
    await CommandsStore.save(_commands);
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _packageInfo = info);
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in _apiKeyControllers.values) {
      c.dispose();
    }
    for (final c in _baseUrlControllers.values) {
      c.dispose();
    }
    _modelAddController.dispose();
    super.dispose();
  }

  void _apply(TerminalSettings next) {
    setState(() => _s = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kSheetBg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Settings',
                style: TextStyle(
                  color: _kFg,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: TerminalPreview(settings: _s),
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: _kFg,
            unselectedLabelColor: _kFgMuted,
            indicatorColor: _kAccent,
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: _kDivider,
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            unselectedLabelStyle: const TextStyle(fontSize: 12),
            tabs: const [
              Tab(text: 'Appearance'),
              Tab(text: 'Font'),
              Tab(text: 'Cursor'),
              Tab(text: 'SSH'),
              Tab(text: 'Commands'),
              Tab(text: 'Agent'),
              Tab(text: 'About'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildAppearanceTab(),
                _buildFontTab(),
                _buildCursorTab(),
                _buildSshTab(),
                _buildCommandsTab(),
                _buildAgentTab(),
                _buildAboutTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Appearance tab: theme preset, custom colors, wallpaper ─────────────────

  Widget _buildAppearanceTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _sectionTitle('Theme'),
        _presetChips(),
        const SizedBox(height: 12),
        _sectionTitle('Colors'),
        _colorRow('Foreground', 'foreground', _s.resolveTheme().foreground),
        _colorRow('Background', 'background', _s.resolveTheme().background),
        _colorRow('Cursor', 'cursor', _s.resolveTheme().cursor),
        _colorRow('Selection', 'selection', _s.resolveTheme().selection),
        const SizedBox(height: 12),
        _sectionTitle('Wallpaper'),
        _wallpaperSection(),
      ],
    );
  }

  // ── Font tab: family, size, line-height, weight ─────────────────────────────

  Widget _buildFontTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _sectionTitle('Family'),
        _fontDropdown(),
        const SizedBox(height: 4),
        Text(
          'Bundled fonts ship with the app and render the same on every '
              'machine; system fonts depend on your OS having them installed.',
          style: const TextStyle(color: _kFgMuted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        _sectionTitle('CJK / 中文'),
        _controlLabel(
          'Fallback for Chinese and other wide characters',
          hint: 'English/code uses JetBrains Mono; '
              '中文 uses this font (e.g. Microsoft YaHei UI)',
        ),
        const SizedBox(height: 6),
        _cjkFontDropdown(),
        const SizedBox(height: 12),
        _sectionTitle('Size & Spacing'),
        _slider(
          label: 'Size',
          value: _s.fontSize,
          min: 10,
          max: 22,
          divisions: 24,
          display: _s.fontSize.toStringAsFixed(1),
          onChanged: (v) => setState(() {
            _s = _s.copyWith(fontSize: double.parse(v.toStringAsFixed(1)));
          }),
          onChangeEnd: (_) => _apply(_s),
        ),
        _slider(
          label: 'Line height',
          hint: 'Vertical spacing between lines',
          value: _s.lineHeight,
          min: 1.0,
          max: 1.5,
          divisions: 10,
          display: _s.lineHeight.toStringAsFixed(2),
          onChanged: (v) => setState(() => _s = _s.copyWith(lineHeight: v)),
          onChangeEnd: (_) => _apply(_s),
        ),
        const SizedBox(height: 12),
        _sectionTitle('Weight'),
        _fontWeightChips(),
      ],
    );
  }

  // ── Cursor tab: shape, blink ────────────────────────────────────────────────

  Widget _buildCursorTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _sectionTitle('Shape'),
        const SizedBox(height: 6),
        _cursorShapeChips(),
        const SizedBox(height: 16),
        _sectionTitle('Blink'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable blinking', style: TextStyle(color: _kFg, fontSize: 13)),
          value: _s.cursorBlink,
          activeTrackColor: _kAccent,
          onChanged: (v) => _apply(_s.copyWith(cursorBlink: v)),
        ),
        if (_s.cursorBlink)
          _slider(
            label: 'Speed',
            value: _blinkSpeedIndex.toDouble(),
            min: 0,
            max: 2,
            divisions: 2,
            display: _blinkSpeedLabel,
            onChanged: (v) => _apply(
              _s.copyWith(cursorBlinkPeriodMs: _periodFromIndex(v.round())),
            ),
          ),
      ],
    );
  }

  // ── Blink helpers ───────────────────────────────────────────────────────────

  int get _blinkSpeedIndex => switch (_s.cursorBlinkPeriodMs) {
        <= 400 => 0,
        >= 700 => 2,
        _ => 1,
      };

  String get _blinkSpeedLabel => switch (_blinkSpeedIndex) {
        0 => 'Fast',
        2 => 'Slow',
        _ => 'Normal',
      };

  int _periodFromIndex(int i) => switch (i) {
        0 => 400,
        2 => 800,
        _ => 530,
      };

  // ── Commands tab ────────────────────────────────────────────────────────────

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

  // ── Agent tab ────────────────────────────────────────────────────────────

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
        _sectionTitle('Providers'),
        for (final p in _agentConfig.providers) _buildProviderCard(p),
      ],
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
          // Header: icon + name + toggle
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
            // API Key
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
            ),
            const SizedBox(height: 8),
            // Base URL
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
            // Models
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
              // If the removed model was the global default, clear it.
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

  static IconData _providerIcon(String id) {
    switch (id) {
      case 'chatgpt':
        return Icons.psychology;
      case 'claude':
        return Icons.auto_awesome;
      case 'gemini':
        return Icons.flutter_dash;
      case 'deepseek':
        return Icons.explore;
      default:
        return Icons.smart_toy;
    }
  }

  // ── About tab ─────────────────────────────────────────────────────────────

  Widget _buildAboutTab() {
    final info = _packageInfo;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _sectionTitle('Application'),
        const SizedBox(height: 4),
        Text(
          'SSTerm',
          style: const TextStyle(
            color: _kFg,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        _sectionTitle('Version'),
        if (info == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _kAccent,
              ),
            ),
          )
        else ...[
          Text(
            info.version,
            style: const TextStyle(
              color: _kFg,
              fontSize: 15,
              fontFamily: 'JetBrainsMono',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Build ${info.buildNumber}',
            style: const TextStyle(color: _kFgMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  // ── SSH tab ─────────────────────────────────────────────────────────────────

  Widget _buildSshTab() {
    final hosts = widget.savedHosts;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle('Saved Hosts')),
            TextButton.icon(
              onPressed: _addHost,
              icon: const Icon(Icons.add, size: 14, color: _kAccent),
              label: const Text('Add', style: TextStyle(color: _kAccent, fontSize: 12)),
            ),
          ],
        ),
        if (hosts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No saved SSH configurations',
                style: TextStyle(color: _kFgMuted, fontSize: 13),
              ),
            ),
          )
        else
          for (final host in hosts) _buildHostTile(host),
      ],
    );
  }

  Widget _buildHostTile(SshHost host) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _kDivider),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        leading: const Icon(Icons.lock_outline, color: _kFgMuted, size: 18),
        title: Text(
          host.alias,
          style: const TextStyle(color: _kFg, fontSize: 13),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          host.displayInfo,
          style: const TextStyle(color: _kFgMuted, fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 15, color: _kFgMuted),
              onPressed: () => _editHost(host),
              tooltip: 'Edit',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.all(6),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 15, color: _kFgMuted),
              onPressed: () => _confirmDeleteHost(host),
              tooltip: 'Delete',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.all(6),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editHost(SshHost host) async {
    final updated = await showEditHostDialog(context, host: host);
    if (updated != null) widget.onSaveHost?.call(host, updated);
  }

  Future<void> _addHost() async {
    final newHost = await showEditHostDialog(context);
    if (newHost != null) widget.onSaveHost?.call(null, newHost);
  }

  Future<void> _confirmDeleteHost(SshHost host) async {
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
                  const Text('Delete Configuration',
                      style: TextStyle(color: _kFg, fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Text('Delete "${host.alias}"?',
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
    if (ok == true) widget.onDeleteHost?.call(host);
  }

  // ── Shared section widget helpers ───────────────────────────────────────────

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: _kFgMuted,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _presetChips() {
    final ids = [...TerminalThemePresets.all.keys, 'custom'];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final id in ids)
          ChoiceChip(
            label: Text(
              TerminalThemePresets.labelFor(id),
              style: TextStyle(
                fontSize: 12,
                color: _s.themePresetId == id ? Colors.white : _kFg,
              ),
            ),
            selected: _s.themePresetId == id,
            selectedColor: _kAccent,
            backgroundColor: _kSurface,
            side: const BorderSide(color: _kDivider),
            onSelected: (_) {
              final next = _s.copyWith();
              next.applyPreset(id);
              _apply(next);
            },
          ),
      ],
    );
  }

  Widget _colorRow(String label, String key, Color color) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label, style: const TextStyle(color: _kFg, fontSize: 13)),
      trailing: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: _kDivider),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      onTap: () async {
        final picked = await showDialog<Color>(
          context: context,
          builder: (ctx) => ColorPickerDialog(initial: color),
        );
        if (picked != null) {
          final next = _s.copyWith();
          next.setCustomColor(key, picked);
          _apply(next);
        }
      },
    );
  }

  Future<void> _pickWallpaper() async {
    if (!ImageFilePicker.isSupported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image picker is not available on this platform.')),
      );
      return;
    }

    final path = await ImageFilePicker.pickPath();
    if (path == null) return;

    final id = await WallpaperStorage.importFrom(path);
    if (id == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not import image.')));
      return;
    }
    if (!mounted) return;

    final hadWallpaper = _s.hasWallpaper;
    _apply(
      _s.copyWith(
        wallpaperId: id,
        wallpaperEnabled: true,
        backgroundOpacity: hadWallpaper ? _s.backgroundOpacity : 0.88,
        wallpaperBlur: hadWallpaper ? _s.wallpaperBlur : 12.0,
      ),
    );
  }

  Future<void> _removeWallpaper() async {
    final id = _s.wallpaperId;
    if (id != null) await WallpaperStorage.delete(id);
    if (!mounted) return;
    _apply(_s.copyWith(clearWallpaper: true));
  }

  Widget _wallpaperSection() {
    final storedFile = WallpaperStorage.resolveFile(_s.wallpaperId);
    final enabled = _s.wallpaperEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Enable wallpaper',
            style: TextStyle(color: _kFg, fontSize: 13),
          ),
          subtitle: Text(
            storedFile == null
                ? 'Choose an image to use as background'
                : enabled
                ? 'Shown behind terminal and tabs'
                : 'Image kept — turn on to show',
            style: const TextStyle(color: _kFgMuted, fontSize: 11),
          ),
          value: enabled,
          activeTrackColor: _kAccent,
          onChanged: (v) {
            if (v && storedFile == null) {
              _pickWallpaper();
              return;
            }
            _apply(_s.copyWith(wallpaperEnabled: v));
          },
        ),
        if (storedFile != null) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Opacity(
              opacity: enabled ? 1.0 : 0.45,
              child: SizedBox(
                height: 72,
                width: double.infinity,
                child: WallpaperBackground(
                  file: storedFile,
                  opacity: _s.wallpaperOpacity,
                  blur: _s.wallpaperBlur,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            TextButton.icon(
              onPressed: _pickWallpaper,
              icon: const Icon(Icons.image_outlined, size: 16, color: _kAccent),
              label: Text(
                storedFile == null ? 'Choose image…' : 'Change image…',
                style: const TextStyle(color: _kAccent, fontSize: 13),
              ),
            ),
            if (storedFile != null) ...[
              const Spacer(),
              TextButton(
                onPressed: _removeWallpaper,
                child: const Text(
                  'Remove',
                  style: TextStyle(color: _kFgMuted, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
        if (storedFile != null && enabled) ...[
          _slider(
            label: 'Opacity',
            hint: 'Image visibility',
            value: _s.wallpaperOpacity,
            min: 0.1,
            max: 1.0,
            divisions: 18,
            display: '${(_s.wallpaperOpacity * 100).round()}%',
            onChanged: (v) => _apply(_s.copyWith(wallpaperOpacity: v)),
          ),
          _slider(
            label: 'Blur',
            hint: 'Frosted-glass effect on the image',
            value: _s.wallpaperBlur,
            min: 0,
            max: 24,
            divisions: 24,
            display: _s.wallpaperBlur.toStringAsFixed(0),
            onChanged: (v) => _apply(_s.copyWith(wallpaperBlur: v)),
          ),
          _slider(
            label: 'Background fill',
            hint: 'Terminal color fill over the image',
            value: _s.backgroundOpacity,
            min: 0.5,
            max: 1.0,
            divisions: 10,
            display: '${(_s.backgroundOpacity * 100).round()}%',
            onChanged: (v) => _apply(_s.copyWith(backgroundOpacity: v)),
          ),
        ],
      ],
    );
  }

  Widget _fontDropdown() {
    final options = TerminalSettings.fontOptions;
    final value = options.contains(_s.fontFamily)
        ? _s.fontFamily
        : TerminalSettings.defaultFontFamily;
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: _kSurface,
      style: const TextStyle(color: _kFg, fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
        enabledBorder:
            UnderlineInputBorder(borderSide: BorderSide(color: _kDivider)),
        focusedBorder:
            UnderlineInputBorder(borderSide: BorderSide(color: _kAccent)),
      ),
      items: [
        for (final f in options)
          DropdownMenuItem(
            value: f,
            child: Text(TerminalSettings.fontFamilyLabel(f)),
          ),
      ],
      onChanged: (v) {
        if (v != null) _apply(_s.copyWith(fontFamily: v));
      },
    );
  }

  Widget _cjkFontDropdown() {
    final options = TerminalSettings.cjkFontOptions;
    final value = options.contains(_s.cjkFontFamily)
        ? _s.cjkFontFamily
        : options.first;
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: _kSurface,
      style: const TextStyle(color: _kFg, fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
        enabledBorder:
            UnderlineInputBorder(borderSide: BorderSide(color: _kDivider)),
        focusedBorder:
            UnderlineInputBorder(borderSide: BorderSide(color: _kAccent)),
      ),
      items: [
        for (final f in options) DropdownMenuItem(value: f, child: Text(f)),
      ],
      onChanged: (v) {
        if (v != null) _apply(_s.copyWith(cjkFontFamily: v));
      },
    );
  }

  Widget _controlLabel(String label, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _kFg, fontSize: 13)),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(hint, style: const TextStyle(color: _kFgMuted, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _fontWeightChips() {
    const options = [
      (FontWeight.w300, 'Light'),
      (FontWeight.w400, 'Normal'),
      (FontWeight.w500, 'Medium'),
      (FontWeight.w600, 'Semibold'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _controlLabel(
          'Thickness of regular text',
          hint: 'Bold output is not affected',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: [
            for (final (w, label) in options)
              ChoiceChip(
                label: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: _s.fontWeight == w ? Colors.white : _kFg,
                  ),
                ),
                selected: _s.fontWeight == w,
                selectedColor: _kAccent,
                backgroundColor: _kSurface,
                side: const BorderSide(color: _kDivider),
                onSelected: (_) => _apply(_s.copyWith(fontWeight: w)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _cursorShapeChips() {
    const shapes = [
      (TerminalCursorType.block, 'Block'),
      (TerminalCursorType.underline, 'Underline'),
      (TerminalCursorType.verticalBar, 'Bar'),
    ];
    return Wrap(
      spacing: 6,
      children: [
        for (final (type, label) in shapes)
          ChoiceChip(
            label: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: _s.cursorType == type ? Colors.white : _kFg,
              ),
            ),
            selected: _s.cursorType == type,
            selectedColor: _kAccent,
            backgroundColor: _kSurface,
            side: const BorderSide(color: _kDivider),
            onSelected: (_) => _apply(_s.copyWith(cursorType: type)),
          ),
      ],
    );
  }

  Widget _slider({
    required String label,
    String? hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(color: _kFg, fontSize: 13)),
            const Spacer(),
            Text(display, style: const TextStyle(color: _kFgMuted, fontSize: 12)),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Text(hint, style: const TextStyle(color: _kFgMuted, fontSize: 11)),
        ],
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: _kAccent,
            thumbColor: _kFg,
            inactiveTrackColor: _kDivider,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ],
    );
  }
}

