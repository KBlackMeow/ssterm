import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/terminal_settings.dart';
import '../services/wallpaper_storage.dart';
import 'wallpaper_background.dart';

/// Static sample lines styled with current [TerminalSettings] (no live Terminal).
///
/// Exercises every visible knob the Settings sheet exposes: ANSI colors,
/// bold / italic / underline text styles, the selection swatch, and a live
/// cursor whose shape, color, and blink rate mirror the current settings.
class TerminalPreview extends StatefulWidget {
  const TerminalPreview({super.key, required this.settings});

  final TerminalSettings settings;

  @override
  State<TerminalPreview> createState() => _TerminalPreviewState();
}

class _TerminalPreviewState extends State<TerminalPreview> {
  Timer? _blinkTimer;
  bool _cursorOn = true;

  @override
  void initState() {
    super.initState();
    _restartBlink();
  }

  @override
  void didUpdateWidget(covariant TerminalPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.settings;
    final old = oldWidget.settings;
    if (s.cursorBlink != old.cursorBlink ||
        s.cursorBlinkPeriodMs != old.cursorBlinkPeriodMs) {
      _restartBlink();
    }
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    super.dispose();
  }

  void _restartBlink() {
    _blinkTimer?.cancel();
    _cursorOn = true;
    if (!widget.settings.cursorBlink) return;
    _blinkTimer = Timer.periodic(
      Duration(milliseconds: widget.settings.cursorBlinkPeriodMs),
      (_) {
        if (!mounted) return;
        setState(() => _cursorOn = !_cursorOn);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final theme = settings.resolveTheme();
    // Leave backgroundColor unset — the outer DecoratedBox already paints the
    // terminal background. Passing `theme.background` here would draw a solid
    // strip per text run on top of it (visible as a black bar behind every
    // line and clipping decorations like underline).
    final base = settings.toTerminalStyle().toTextStyle(
      color: theme.foreground,
    );

    TextStyle c(
      Color color, {
      bool bold = false,
      bool italic = false,
      bool underline = false,
      Color? bg,
    }) =>
        base.copyWith(
          color: color,
          backgroundColor: bg,
          fontWeight: bold ? FontWeight.bold : base.fontWeight,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          decoration:
              underline ? TextDecoration.underline : TextDecoration.none,
          decorationColor: color,
        );

    final wallpaper = settings.hasWallpaper
        ? WallpaperStorage.resolveFile(settings.wallpaperId)
        : null;
    final bgOpacity = settings.effectiveBackgroundOpacity;

    // Approximate monospace cell metrics — good enough for a static preview
    // without measuring an actual TextPainter.
    final cellWidth = settings.fontSize * 0.6;
    final cellHeight = settings.fontSize * settings.lineHeight;

    final cursor = _CursorGlyph(
      type: settings.cursorType,
      color: theme.cursor,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      visible: settings.cursorBlink ? _cursorOn : true,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 128,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (wallpaper != null)
              WallpaperBackground(
                file: wallpaper,
                opacity: settings.wallpaperOpacity,
                blur: settings.wallpaperBlur,
              )
            else
              ColoredBox(color: theme.background),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.background.withValues(alpha: bgOpacity),
                border: Border.all(color: const Color(0xFF3A3A3A)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: DefaultTextStyle(
                  style: base,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'SSTerm ',
                              style: c(const Color(0xFFFD971F)),
                            ),
                            TextSpan(text: 'ok ', style: c(theme.green)),
                            TextSpan(text: 'err ', style: c(theme.red)),
                            TextSpan(text: 'warn ', style: c(theme.yellow)),
                            TextSpan(text: 'info', style: c(theme.blue)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'bold ',
                              style: c(theme.foreground, bold: true),
                            ),
                            TextSpan(
                              text: 'italic ',
                              style: c(theme.cyan, italic: true),
                            ),
                            TextSpan(
                              text: 'under ',
                              style: c(theme.magenta, underline: true),
                            ),
                            TextSpan(
                              text: 'select',
                              style: c(theme.foreground, bg: theme.selection),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '\$ ',
                                  style: c(theme.brightBlack),
                                ),
                                TextSpan(
                                  text: 'echo hello',
                                  style: c(theme.foreground),
                                ),
                              ],
                            ),
                          ),
                          cursor,
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Visual stand-in for the live terminal cursor — shape, color and visibility
/// (blink) come from the current [TerminalSettings].
class _CursorGlyph extends StatelessWidget {
  const _CursorGlyph({
    required this.type,
    required this.color,
    required this.cellWidth,
    required this.cellHeight,
    required this.visible,
  });

  final TerminalCursorType type;
  final Color color;
  final double cellWidth;
  final double cellHeight;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return SizedBox(width: cellWidth, height: cellHeight);
    }
    switch (type) {
      case TerminalCursorType.block:
        return Container(
          width: cellWidth,
          height: cellHeight,
          color: color,
        );
      case TerminalCursorType.underline:
        return SizedBox(
          width: cellWidth,
          height: cellHeight,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Container(
              width: cellWidth,
              height: 2,
              color: color,
            ),
          ),
        );
      case TerminalCursorType.verticalBar:
        return SizedBox(
          width: cellWidth,
          height: cellHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 2,
              height: cellHeight,
              color: color,
            ),
          ),
        );
    }
  }
}
