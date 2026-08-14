import 'dart:io';

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
  const CmdPickerButton({super.key, required this.onInsert, this.loadCommands});

  final ValueChanged<String>? onInsert;
  final Future<List<Command>> Function()? loadCommands;

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
    final cmds = await _loadCommands();
    if (!mounted) return;
    _commands = cmds;
  }

  Future<List<Command>> _loadCommands() =>
      widget.loadCommands?.call() ?? CommandsStore.load();

  // ── Desktop: frosted popup menu ─────────────────────────────────────────────

  Future<void> _showDesktopMenu(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    final cmds = await _loadCommands();
    if (!mounted) return;
    _commands = cmds;

    final items = <PopupMenuEntry<int>>[
      PopupMenuItem<int>(
        enabled: false,
        height: 40,
        padding: EdgeInsets.zero,
        child: Builder(
          builder: (ctx) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Insert command',
              style: _menuTextStyle(
                color:
                    AppColors.maybeOf(ctx)?.foregroundDim ??
                    const Color(0xFF6E6E6E),
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
      const PopupMenuDivider(height: 1),
      if (_commands.isEmpty)
        PopupMenuItem<int>(
          enabled: false,
          height: 56,
          padding: EdgeInsets.zero,
          child: Builder(
            builder: (ctx) {
              final dim = AppColors.maybeOf(ctx)?.foregroundDim ?? _kFgInactive;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'No saved commands',
                      style: _menuTextStyle(color: dim, fontSize: 13),
                    ),
                    Text(
                      'Add commands in Settings > Commands.',
                      style: _menuTextStyle(color: dim, fontSize: 11),
                    ),
                  ],
                ),
              );
            },
          ),
        )
      else
        for (var i = 0; i < _commands.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 44,
            padding: EdgeInsets.zero,
            child: Builder(
              builder: (ctx) {
                final fg = AppColors.maybeOf(ctx)?.foreground ?? _kFgActive;
                final dim =
                    AppColors.maybeOf(ctx)?.foregroundDim ?? _kFgInactive;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _commands[i].name,
                        style: _menuTextStyle(color: fg, fontSize: 13),
                      ),
                      Text(
                        _commands[i].description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _menuTextStyle(color: dim, fontSize: 11),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
    ];

    showFrostedMenu<int>(
      context: this.context,
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
    final cmds = await _loadCommands();
    if (!mounted) return;
    _commands = cmds;
    if (!context.mounted) return;

    // Capture theme before entering the dialog route which loses local Theme.
    final popupColor =
        AppColors.maybeOf(context)?.popup ?? FrostedGlassStyle.menuFillFrosted;
    final menuColors = AppColors.fromBackground(popupColor);
    final parentTheme = Theme.of(context);

    final idx = await showGeneralDialog<int>(
      context: context,
      useRootNavigator: false,
      barrierColor: const Color(0x66000000),
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, _, _) {
        final screenH = MediaQuery.of(ctx).size.height;
        return Theme(
          data: parentTheme.copyWith(extensions: {menuColors}),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 360,
                  maxHeight: screenH * 0.55,
                ),
                child: _CmdPickerSheet(
                  commands: _commands,
                  popupColor: popupColor,
                ),
              ),
            ),
          ),
        );
      },
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
              Icons.code,
              size: 20,
              color: enabled
                  ? AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive
                  : (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
                        .withAlpha(60),
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
            Icons.code,
            size: 15,
            color: enabled
                ? AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive
                : (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
                      .withAlpha(80),
          ),
        ),
      ),
    );
  }
}

// ── Mobile centered dialog — matches desktop frosted menu style ───────────────

class _CmdPickerSheet extends StatelessWidget {
  const _CmdPickerSheet({required this.commands, this.popupColor});

  final List<Command> commands;
  final Color? popupColor;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final fg = colors?.foreground ?? _kFgActive;
    final dim = colors?.foregroundDim ?? _kFgInactive;
    final headerDim = colors?.foregroundDim ?? const Color(0xFF6E6E6E);
    final fill = popupColor ?? FrostedGlassStyle.menuFillFrosted;

    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          'Insert command',
          style: _menuTextStyle(
            color: headerDim,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      const Divider(height: 1, color: FrostedGlassStyle.divider),
      if (commands.isEmpty)
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No saved commands',
                style: _menuTextStyle(color: dim, fontSize: 13),
              ),
              const SizedBox(height: 2),
              Text(
                'Add commands in Settings > Commands.',
                style: _menuTextStyle(color: dim, fontSize: 11),
              ),
            ],
          ),
        )
      else
        for (var i = 0; i < commands.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: FrostedGlassStyle.divider),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => Navigator.pop(context, i),
              overlayColor: WidgetStateProperty.all(const Color(0x14FFFFFF)),
              child: SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        commands[i].name,
                        style: _menuTextStyle(color: fg, fontSize: 13),
                      ),
                      Text(
                        commands[i].description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _menuTextStyle(color: dim, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
    ];

    return PopupSurface(
      color: fill,
      backdropBlur: 24,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }
}
