import 'package:flutter/material.dart';

import '../../models/command.dart';

const _kSheetBg = Color(0xFF111113);
const _kDivider = Color(0xFF252525);
const _kFg = Color(0xFFD4D4D4);
const _kFgMuted = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);

// ── Color picker dialog ──────────────────────────────────────────────────────

class ColorPickerDialog extends StatefulWidget {
  const ColorPickerDialog({super.key, required this.initial});

  final Color initial;

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
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

class CommandDialog extends StatefulWidget {
  const CommandDialog({super.key, this.existing});

  final Command? existing;

  @override
  State<CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<CommandDialog> {
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
