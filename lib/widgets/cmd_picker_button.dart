import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/command.dart';
import '../models/commands_store.dart';
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
    this.chromeBackground = const Color(0xFF161820),
  });

  final ValueChanged<String>? onInsert;
  final bool frostedGlass;
  final Color chromeBackground;

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
    final cmds = await CommandsStore.load();
    if (!mounted) return;
    _commands = cmds;
  }

  // ── Desktop: frosted popup menu ─────────────────────────────────────────────

  Future<void> _showDesktopMenu(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    final cmds = await CommandsStore.load();
    if (!mounted) return;
    _commands = cmds;
    if (_commands.isEmpty) return;

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
      context: this.context,
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

  // ── Mobile: bottom sheet ────────────────────────────────────────────────────

  Future<void> _showMobileSheet(BuildContext context) async {
    final cmds = await CommandsStore.load();
    if (!mounted) return;
    _commands = cmds;
    if (_commands.isEmpty) return;
    if (!context.mounted) return;

    final idx = await showDialog<int>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 48,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: _CmdPickerSheet(
          commands: _commands,
          frostedGlass: widget.frostedGlass,
          chromeBackground: widget.chromeBackground,
        ),
      ),
      ),
    );
    if (idx == null) return;
    widget.onInsert?.call(_commands[idx].command);
  }

  Future<void> _showPicker(BuildContext context) {
    if (Platform.isIOS || Platform.isAndroid) {
      return _showMobileSheet(context);
    }
    return _showDesktopMenu(context);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onInsert != null;
    final isMobile = Platform.isIOS || Platform.isAndroid;

    // Mobile: full-bar-height tap area with 20 px icon.
    // Desktop: compact 28×28 container with 15 px icon.
    if (isMobile) {
      return Tooltip(
        message: 'Insert command',
        child: GestureDetector(
          onTap: enabled ? () => _showPicker(context) : null,
          child: SizedBox(
            width: 44,
            height: double.infinity,
            child: Icon(
              Icons.terminal,
              size: 20,
              color: enabled
                  ? _kFgInactive
                  : _kFgInactive.withAlpha(60),
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: 'Insert command',
      child: GestureDetector(
        onTap: enabled ? () => _showPicker(context) : null,
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

// ── Mobile bottom sheet ───────────────────────────────────────────────────────

class _CmdPickerSheet extends StatelessWidget {
  const _CmdPickerSheet({
    required this.commands,
    required this.frostedGlass,
    this.chromeBackground = const Color(0xFF161820),
  });

  final List<Command> commands;
  final bool frostedGlass;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(16));

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          child: Row(
            children: [
              const Icon(
                Icons.terminal_rounded,
                size: 18,
                color: Color(0xFF2472C8),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Insert Command',
                  style: TextStyle(
                    color: _kFgActive,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF252838),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${commands.length}',
                  style: const TextStyle(
                    color: _kFgInactive,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Commands card
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              // Section label
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 6),
                child: Text(
                  'COMMANDS',
                  style: TextStyle(
                    color: _kFgInactive.withAlpha(180),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              // Card
              _CmdCard(commands: commands),
            ],
          ),
        ),
      ],
    );

    if (frostedGlass) {
      return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: const BoxDecoration(
              color: FrostedGlassStyle.panelFillFrosted,
              borderRadius: radius,
            ),
            child: content,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: chromeBackground,
        borderRadius: radius,
      ),
      child: content,
    );
  }
}

class _CmdCard extends StatelessWidget {
  const _CmdCard({required this.commands});

  final List<Command> commands;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF252838),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF353848), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < commands.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                indent: 52,
                color: Color(0xFF252838),
              ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => Navigator.pop(context, i),
                overlayColor: WidgetStateProperty.all(
                  const Color(0x10FFFFFF),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFF252838),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.terminal_rounded,
                          size: 16,
                          color: Color(0xFF2472C8),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              commands[i].name,
                              style: const TextStyle(
                                color: _kFgActive,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (commands[i].description.isNotEmpty)
                              Text(
                                commands[i].description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _kFgInactive,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: Color(0xFF3A3A4A),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
