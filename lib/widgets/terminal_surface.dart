import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/terminal_settings.dart';
import '../services/wallpaper_storage.dart';
import 'crt_overlay.dart';
import 'frosted_glass.dart';
import 'wallpaper_background.dart';

const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);

class TerminalContextMenuConfig {
  const TerminalContextMenuConfig({
    required this.controller,
    this.canSplit = false,
    this.isSplit = false,
    this.onSplitHorizontal,
    this.onSplitVertical,
  });

  final TerminalController controller;
  final bool canSplit;
  final bool isSplit;
  final VoidCallback? onSplitHorizontal;
  final VoidCallback? onSplitVertical;
}

/// Terminal view with optional full-bleed wallpaper behind semi-transparent cells.
class TerminalSurface extends StatelessWidget {
  const TerminalSurface({
    super.key,
    required this.terminal,
    required this.settings,
    this.viewKey,
    this.padding = const EdgeInsets.all(6),
    this.autofocus = true,
    // IME (e.g. Chinese) needs [CustomTextEdit] / TextInput, not hardware keys only.
    this.hardwareKeyboardOnly = false,
    this.contextMenu,
    this.frostedGlass = true,
    /// When false, wallpaper is expected from a parent (e.g. app chrome / tab bar).
    this.includeWallpaper = true,
    /// When false, CRT is expected from a parent (e.g. full window chrome).
    this.includeCrt = true,
  });

  final Terminal terminal;
  final TerminalSettings settings;
  final GlobalKey<TerminalViewState>? viewKey;
  final EdgeInsets padding;
  final bool autofocus;
  final bool hardwareKeyboardOnly;
  final TerminalContextMenuConfig? contextMenu;
  final bool frostedGlass;
  final bool includeWallpaper;
  final bool includeCrt;

  void _showContextMenu(BuildContext context, Offset position) {
    final config = contextMenu!;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final relativeRect = RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    );

    showFrostedMenu<String>(
      context: context,
      frostedGlass: frostedGlass,
      position: relativeRect,
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          height: 36,
          child: _menuRow(Icons.content_copy, 'Copy'),
        ),
        PopupMenuItem<String>(
          value: 'paste',
          height: 36,
          child: _menuRow(Icons.content_paste, 'Paste'),
        ),
        if (config.canSplit) ...[
          const PopupMenuDivider(height: 1),
          PopupMenuItem<String>(
            value: 'split_h',
            height: 36,
            child: _menuRow(Icons.vertical_split, 'Split horizontally'),
          ),
          PopupMenuItem<String>(
            value: 'split_v',
            height: 36,
            child: _menuRow(Icons.splitscreen, 'Split vertically'),
          ),
        ],
      ],
    ).then((value) async {
      if (value == 'copy') {
        final selection = config.controller.selection;
        if (selection != null) {
          final text = terminal.buffer.getText(selection);
          if (text.isNotEmpty) {
            await Clipboard.setData(ClipboardData(text: text));
          }
        }
      } else if (value == 'paste') {
        final data = await Clipboard.getData('text/plain');
        if (data?.text != null && data!.text!.isNotEmpty) {
          terminal.paste(data.text!);
        }
      } else if (value == 'split_h') {
        config.onSplitHorizontal?.call();
      } else if (value == 'split_v') {
        config.onSplitVertical?.call();
      }
    });
  }

  static Widget _menuRow(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, size: 13, color: _kFgInactive),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: _kFgActive, fontSize: 13)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = settings;
    final terminalView = TerminalView(
      key: viewKey,
      terminal,
      controller: contextMenu?.controller,
      theme: t.resolveTheme(),
      textStyle: t.toTerminalStyle(),
      cursorType: t.cursorType,
      cursorBlink: t.cursorBlink,
      cursorBlinkPeriodMs: t.cursorBlinkPeriodMs,
      textScaler: TextScaler.linear(t.textScale),
      padding: padding,
      autofocus: autofocus,
      hardwareKeyboardOnly: hardwareKeyboardOnly,
      keyboardType: TextInputType.text,
      backgroundOpacity: t.effectiveBackgroundOpacity,
      onSecondaryTapUp: contextMenu != null
          ? (details, _) => _showContextMenu(context, details.globalPosition)
          : null,
    );

    final wallpaper = includeWallpaper && t.hasWallpaper
        ? WallpaperStorage.resolveFile(t.wallpaperId)
        : null;

    Widget surface = wallpaper == null
        ? terminalView
        : Stack(
            fit: StackFit.expand,
            children: [
              WallpaperBackground(
                file: wallpaper,
                opacity: t.wallpaperOpacity,
                blur: t.wallpaperBlur,
              ),
              terminalView,
            ],
          );

    if (includeCrt && t.crt.enabled) {
      surface = CrtOverlay(settings: t.crt, child: surface);
    }

    return surface;
  }
}
