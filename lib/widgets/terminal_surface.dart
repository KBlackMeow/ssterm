import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/terminal_settings.dart';
import '../services/wallpaper_storage.dart';
import 'wallpaper_background.dart';

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
  });

  final Terminal terminal;
  final TerminalSettings settings;
  final GlobalKey<TerminalViewState>? viewKey;
  final EdgeInsets padding;
  final bool autofocus;
  final bool hardwareKeyboardOnly;

  @override
  Widget build(BuildContext context) {
    final t = settings;
    final terminalView = TerminalView(
      key: viewKey,
      terminal,
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
    );

    final wallpaper = WallpaperStorage.resolveFile(t.wallpaperId);
    if (wallpaper == null) return terminalView;

    return Stack(
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
  }
}
