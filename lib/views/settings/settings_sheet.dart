import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

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

Future<void> showTerminalSettingsSheet(
  BuildContext context, {
  required TerminalSettings settings,
  required ValueChanged<TerminalSettings> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: _kSheetBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
    ),
    builder: (ctx) => _SettingsSheet(
      settings: settings,
      onChanged: onChanged,
    ),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.settings,
    required this.onChanged,
  });

  final TerminalSettings settings;
  final ValueChanged<TerminalSettings> onChanged;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late TerminalSettings _s;

  @override
  void initState() {
    super.initState();
    _s = widget.settings.copyWith();
  }

  void _apply(TerminalSettings next) {
    setState(() => _s = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (_, scroll) => Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: _kDivider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Text(
                    'Terminal Settings',
                    style: TextStyle(
                      color: _kFg,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: _kFgMuted, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TerminalPreview(settings: _s),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _sectionTitle('Color scheme'),
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
                  _sectionTitle('Font'),
                  _controlLabel('Family'),
                  _fontDropdown(),
                  _slider(
                    label: 'Size',
                    value: _s.fontSize,
                    min: 10,
                    max: 22,
                    divisions: 24,
                    display: _s.fontSize.toStringAsFixed(1),
                    onChanged: (v) =>
                        _apply(_s.copyWith(fontSize: double.parse(v.toStringAsFixed(1)))),
                  ),
                  _slider(
                    label: 'Line height',
                    hint: 'Vertical spacing between lines',
                    value: _s.lineHeight,
                    min: 1.0,
                    max: 1.5,
                    divisions: 10,
                    display: _s.lineHeight.toStringAsFixed(2),
                    onChanged: (v) => _apply(_s.copyWith(lineHeight: v)),
                  ),
                  _fontWeightChips(),
                  const SizedBox(height: 12),
                  _sectionTitle('Cursor'),
                  _controlLabel('Shape'),
                  _cursorShapeChips(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Blink', style: TextStyle(color: _kFg, fontSize: 13)),
                    value: _s.cursorBlink,
                    activeTrackColor: _kAccent,
                    onChanged: (v) => _apply(_s.copyWith(cursorBlink: v)),
                  ),
                  if (_s.cursorBlink)
                    _slider(
                      label: 'Blink speed',
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
              ),
            ),
          ],
        ),
      ),
    );
  }

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

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text,
          style: const TextStyle(
            color: _kFgMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      );

  Widget _presetChips() {
    final ids = [
      ...TerminalThemePresets.all.keys,
      'custom',
    ];
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
        const SnackBar(
          content: Text('Image picker is only available on macOS.'),
        ),
      );
      return;
    }

    final path = await ImageFilePicker.pickPath();
    if (path == null) return;

    final id = await WallpaperStorage.importFrom(path);
    if (id == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not import image.')),
      );
      return;
    }
    if (!mounted) return;

    final hadWallpaper = _s.hasWallpaper;
    _apply(
      _s.copyWith(
        wallpaperId: id,
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
    final file = WallpaperStorage.resolveFile(_s.wallpaperId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (file != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 72,
              width: double.infinity,
              child: WallpaperBackground(
                file: file,
                opacity: _s.wallpaperOpacity,
                blur: _s.wallpaperBlur,
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
                file == null ? 'Choose image…' : 'Change image…',
                style: const TextStyle(color: _kAccent, fontSize: 13),
              ),
            ),
            if (file != null) ...[
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
        if (file != null) ...[
          _slider(
            label: 'Wallpaper',
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
            label: 'Background',
            hint: 'Terminal fill over the image',
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
    return DropdownButtonFormField<String>(
      initialValue: TerminalSettings.fontOptions.contains(_s.fontFamily)
          ? _s.fontFamily
          : TerminalSettings.fontOptions.first,
      dropdownColor: const Color(0xFF1C1C1C),
      style: const TextStyle(color: _kFg, fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: _kDivider)),
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _kAccent)),
      ),
      items: [
        for (final f in TerminalSettings.fontOptions)
          DropdownMenuItem(value: f, child: Text(f)),
      ],
      onChanged: (v) {
        if (v != null) _apply(_s.copyWith(fontFamily: v));
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
      (FontWeight.normal, 'Normal'),
      (FontWeight.w500, 'Medium'),
      (FontWeight.w600, 'Semibold'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _controlLabel(
          'Weight',
          hint: 'Thickness of regular text (bold output is unchanged)',
        ),
        const SizedBox(height: 6),
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
          ),
        ),
      ],
    );
  }
}

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
