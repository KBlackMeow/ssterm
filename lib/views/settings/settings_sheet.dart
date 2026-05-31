import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:xterm/xterm.dart';

import '../../dialogs/connect_dialog.dart' show showEditHostDialog;
import '../../models/command.dart';
import '../../models/commands_store.dart';
import '../../models/ssh_host.dart';
import '../../models/terminal_settings.dart';
import '../../models/terminal_theme_presets.dart';
import '../../services/image_file_picker.dart';
import '../../services/wallpaper_storage.dart';
import '../../widgets/terminal_preview.dart';
import '../../widgets/wallpaper_background.dart';

const _kSheetBg = Color(0xFF2B2B2B);
const _kDivider = Color(0xFF3A3A3A);
const _kFg = Color(0xFFD4D4D4);
const _kFgMuted = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.sftpFrostedGlass = true,
    this.onSftpFrostedGlassChanged,
    this.savedHosts = const [],
    this.onSaveHost,
    this.onDeleteHost,
  });

  final TerminalSettings settings;
  final ValueChanged<TerminalSettings> onChanged;
  final bool sftpFrostedGlass;
  final ValueChanged<bool>? onSftpFrostedGlassChanged;
  final List<SshHost> savedHosts;
  final void Function(SshHost? original, SshHost updated)? onSaveHost;
  final ValueChanged<SshHost>? onDeleteHost;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  late TerminalSettings _s;
  late TabController _tabController;
  PackageInfo? _packageInfo;
  List<Command> _commands = const [];

  @override
  void initState() {
    super.initState();
    _s = widget.settings.copyWith();
    _tabController = TabController(length: 6, vsync: this);
    _loadPackageInfo();
    _loadCommands();
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
        const SizedBox(height: 12),
        _sectionTitle('SFTP panel'),
        _sftpPanelSection(),
      ],
    );
  }

  Widget _sftpPanelSection() {
    final onChanged = widget.onSftpFrostedGlassChanged;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text(
        'Frosted glass',
        style: TextStyle(color: _kFg, fontSize: 13),
      ),
      subtitle: const Text(
        'SFTP, tab bar menus, and right-click context menus',
        style: TextStyle(color: _kFgMuted, fontSize: 11),
      ),
      value: widget.sftpFrostedGlass,
      activeTrackColor: _kAccent,
      onChanged: onChanged == null ? null : (v) => onChanged(v),
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
        color: const Color(0xFF1C1C1C),
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
      builder: (ctx) => AlertDialog(
        backgroundColor: _kSheetBg,
        title: const Text('Delete Command', style: TextStyle(color: _kFg, fontSize: 15)),
        content: Text(
          'Delete "${cmd.name}"?',
          style: const TextStyle(color: _kFgMuted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _kFgMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF6E67))),
          ),
        ],
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
      builder: (ctx) => _CommandDialog(existing: existing),
    );
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
            Expanded(child: _sectionTitle('Saved Connections')),
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
        color: const Color(0xFF1C1C1C),
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
      builder: (ctx) => AlertDialog(
        backgroundColor: _kSheetBg,
        title: const Text('Delete Configuration', style: TextStyle(color: _kFg, fontSize: 15)),
        content: Text(
          'Delete "${host.alias}"?',
          style: const TextStyle(color: _kFgMuted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _kFgMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF6E67))),
          ),
        ],
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
            backgroundColor: const Color(0xFF1C1C1C),
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
          builder: (ctx) => _ColorPickerDialog(initial: color),
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
        const SnackBar(content: Text('Image picker is only available on macOS.')),
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
      dropdownColor: const Color(0xFF1C1C1C),
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
      dropdownColor: const Color(0xFF1C1C1C),
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
                backgroundColor: const Color(0xFF1C1C1C),
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
            backgroundColor: const Color(0xFF1C1C1C),
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

// ── Color picker dialog ──────────────────────────────────────────────────────

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});

  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late Color _color;

  static const _swatches = [
    Color(0xFF1C1C1C),
    Color(0xFF282C34),
    Color(0xFF282A36),
    Color(0xFF000000),
    Color(0xFFC7C7C7),
    Color(0xFFFFFFFF),
    Color(0xFFD4D4D4),
    Color(0xFF2472C8),
    Color(0xFF00C200),
    Color(0xFFC91B00),
    Color(0xFFC7C400),
    Color(0xFFC930C7),
    Color(0xFF00C5C7),
    Color(0xFF4E6F91),
    Color(0xFFFF6E67),
    Color(0xFF5FFA68),
  ];

  @override
  void initState() {
    super.initState();
    _color = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kSheetBg,
      title: const Text('Pick color', style: TextStyle(color: _kFg, fontSize: 15)),
      content: SizedBox(
        width: 280,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in _swatches)
              GestureDetector(
                onTap: () => setState(() => _color = c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c,
                    border: Border.all(
                      color: _color == c ? _kAccent : _kDivider,
                      width: _color == c ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: _kFgMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _color),
          child: const Text('Apply', style: TextStyle(color: _kAccent)),
        ),
      ],
    );
  }
}

// ── Command edit dialog ──────────────────────────────────────────────────────

class _CommandDialog extends StatefulWidget {
  const _CommandDialog({this.existing});

  final Command? existing;

  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _cmdCtrl;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _cmdCtrl = TextEditingController(text: e?.command ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _cmdCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final cmd = _cmdCtrl.text.trim();
    if (name.isEmpty || cmd.isEmpty) return;
    Navigator.pop(
      context,
      Command(
        name: name,
        description: _descCtrl.text.trim(),
        command: cmd,
      ),
    );
  }

  InputDecoration _fieldDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: _kFgMuted, fontSize: 12),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
        enabledBorder:
            const UnderlineInputBorder(borderSide: BorderSide(color: _kDivider)),
        focusedBorder:
            const UnderlineInputBorder(borderSide: BorderSide(color: _kAccent)),
      );

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      backgroundColor: _kSheetBg,
      title: Text(
        isEdit ? 'Edit Command' : 'New Command',
        style: const TextStyle(color: _kFg, fontSize: 15),
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: _kFg, fontSize: 13),
              decoration: _fieldDecoration('Name *'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _descCtrl,
              style: const TextStyle(color: _kFg, fontSize: 13),
              decoration: _fieldDecoration('Description'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _cmdCtrl,
              style: const TextStyle(
                color: _kFg,
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
              ),
              decoration: _fieldDecoration('Command *'),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              maxLines: 5,
              minLines: 1,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: _kFgMuted)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            isEdit ? 'Save' : 'Add',
            style: const TextStyle(color: _kAccent),
          ),
        ),
      ],
    );
  }
}
