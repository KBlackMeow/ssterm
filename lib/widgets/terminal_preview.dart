import 'package:flutter/material.dart';

import '../models/terminal_settings.dart';

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

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 88,
        width: double.infinity,
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.background,
          border: Border.all(color: const Color(0xFF3A3A3A)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: DefaultTextStyle(
          style: base,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'ssterm ', style: c(const Color(0xFFFD971F))),
                    TextSpan(text: 'ok ', style: c(theme.green)),
                    TextSpan(text: 'err ', style: c(theme.red)),
                    TextSpan(text: 'warn ', style: c(theme.yellow)),
                    TextSpan(text: 'info', style: c(theme.blue)),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'bold ', style: c(theme.foreground, bold: true)),
                    TextSpan(
                      text: 'italic',
                      style: c(theme.cyan, italic: true),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text('\$ echo hello', style: c(theme.brightBlack)),
            ],
          ),
        ),
      ),
    );
  }
}
