import 'package:flutter/material.dart';

import '../models/terminal_settings.dart';
import '../services/wallpaper_storage.dart';
import 'wallpaper_background.dart';

/// Static sample lines styled with current [TerminalSettings] (no live Terminal).
class TerminalPreview extends StatelessWidget {
  const TerminalPreview({super.key, required this.settings});

  final TerminalSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = settings.resolveTheme();
    final base = settings.toTerminalStyle().toTextStyle(
      color: theme.foreground,
      backgroundColor: theme.background,
    );

    TextStyle c(Color color, {bool bold = false, bool italic = false}) =>
        base.copyWith(
          color: color,
          fontWeight: bold ? FontWeight.bold : base.fontWeight,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        );

    final wallpaper = settings.hasWallpaper
        ? WallpaperStorage.resolveFile(settings.wallpaperId)
        : null;
    final bgOpacity = settings.effectiveBackgroundOpacity;

    Widget preview = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 96,
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
                              text: '\$ echo hello',
                              style: c(theme.brightBlack),
                            ),
                          ],
                        ),
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

    return preview;
  }
}
