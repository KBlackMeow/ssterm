import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/command.dart';

const _kBg = Color(0xFF2B2B2B);
const _kDivider = Color(0xFF3A3A3A);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);

class CmdPickerButton extends StatefulWidget {
  const CmdPickerButton({super.key, required this.onInsert});

  final ValueChanged<String>? onInsert;

  @override
  State<CmdPickerButton> createState() => _CmdPickerButtonState();
}

class _CmdPickerButtonState extends State<CmdPickerButton> {
  List<Command> _commands = const [];

  @override
  void initState() {
    super.initState();
    _preload();
  }

  Future<void> _preload() async {
    final raw = await rootBundle.loadString('assets/scripts/cmd.json');
    final list = jsonDecode(raw) as List<dynamic>;
    if (!mounted) return;
    _commands =
        list.map((e) => Command.fromJson(e as Map<String, dynamic>)).toList();
  }

  void _showMenu(BuildContext context) {
    if (_commands.isEmpty) return;

    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    final items = <PopupMenuEntry<int>>[
      const PopupMenuItem<int>(
        enabled: false,
        height: 28,
        child: Text(
          'Insert command',
          style: TextStyle(
            color: Color(0xFF6E6E6E),
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      const PopupMenuDivider(height: 1),
      for (var i = 0; i < _commands.length; i++)
        PopupMenuItem<int>(
          value: i,
          height: 44,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _commands[i].name,
                style: const TextStyle(color: _kFgActive, fontSize: 13),
              ),
              Text(
                _commands[i].description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _kFgInactive, fontSize: 11),
              ),
            ],
          ),
        ),
    ];

    showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
      ),
      color: _kBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: _kDivider),
      ),
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
      items: items,
    ).then((idx) {
      if (idx == null) return;
      widget.onInsert?.call(_commands[idx].command);
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onInsert != null;
    return Tooltip(
      message: 'Insert command',
      child: GestureDetector(
        onTap: enabled ? () => _showMenu(context) : null,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(
            Icons.terminal,
            size: 15,
            color: enabled ? _kFgInactive : _kFgInactive.withAlpha(80),
          ),
        ),
      ),
    );
  }
}
