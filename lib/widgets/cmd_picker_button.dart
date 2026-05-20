import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/command.dart';
import 'frosted_glass.dart';

const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);

/// UI font that covers Latin and CJK in one face so mixed labels do not
/// alternate between Segoe UI and SimSun/YaHei on Windows.
String? get _menuFontFamily {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'Microsoft YaHei UI';
    case TargetPlatform.macOS:
      return 'PingFang SC';
    case TargetPlatform.linux:
      return 'Noto Sans CJK SC';
    default:
      return null;
  }
}

TextStyle _menuTextStyle({
  required Color color,
  required double fontSize,
  FontWeight fontWeight = FontWeight.w400,
  double? letterSpacing,
}) {
  return TextStyle(
    color: color,
    fontSize: fontSize,
    fontWeight: fontWeight,
    letterSpacing: letterSpacing,
    fontFamily: _menuFontFamily,
  );
}

class CmdPickerButton extends StatefulWidget {
  const CmdPickerButton({
    super.key,
    required this.onInsert,
    this.frostedGlass = true,
  });

  final ValueChanged<String>? onInsert;
  final bool frostedGlass;

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
      PopupMenuItem<int>(
        enabled: false,
        height: 28,
        child: Text(
          'Insert command',
          style: _menuTextStyle(
            color: const Color(0xFF6E6E6E),
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
                style: _menuTextStyle(color: _kFgActive, fontSize: 13),
              ),
              Text(
                _commands[i].description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _menuTextStyle(color: _kFgInactive, fontSize: 11),
              ),
            ],
          ),
        ),
    ];

    showFrostedMenu<int>(
      context: context,
      frostedGlass: widget.frostedGlass,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height,
        pos.dx + box.size.width,
        pos.dy,
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
