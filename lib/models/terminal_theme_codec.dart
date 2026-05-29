import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import 'terminal_theme_presets.dart';

/// JSON helpers for [TerminalTheme] colors (`#AARRGGBB` or `#RRGGBB`).
abstract final class TerminalThemeCodec {
  static String colorToJson(Color color) {
    final v = color.toARGB32();
    return '#${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  static Color colorFromJson(String hex) {
    var s = hex.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return const Color(0xFFFFFFFF);
    return Color(int.parse(s, radix: 16));
  }

  static Map<String, dynamic> themeToJson(TerminalTheme theme) => {
        'cursor': colorToJson(theme.cursor),
        'selection': colorToJson(theme.selection),
        'foreground': colorToJson(theme.foreground),
        'background': colorToJson(theme.background),
        'black': colorToJson(theme.black),
        'red': colorToJson(theme.red),
        'green': colorToJson(theme.green),
        'yellow': colorToJson(theme.yellow),
        'blue': colorToJson(theme.blue),
        'magenta': colorToJson(theme.magenta),
        'cyan': colorToJson(theme.cyan),
        'white': colorToJson(theme.white),
        'brightBlack': colorToJson(theme.brightBlack),
        'brightRed': colorToJson(theme.brightRed),
        'brightGreen': colorToJson(theme.brightGreen),
        'brightYellow': colorToJson(theme.brightYellow),
        'brightBlue': colorToJson(theme.brightBlue),
        'brightMagenta': colorToJson(theme.brightMagenta),
        'brightCyan': colorToJson(theme.brightCyan),
        'brightWhite': colorToJson(theme.brightWhite),
        'searchHitBackground': colorToJson(theme.searchHitBackground),
        'searchHitBackgroundCurrent':
            colorToJson(theme.searchHitBackgroundCurrent),
        'searchHitForeground': colorToJson(theme.searchHitForeground),
      };

  static TerminalTheme themeFromJson(Map<String, dynamic> json) {
    Color c(String key, Color fallback) =>
        json[key] is String ? colorFromJson(json[key] as String) : fallback;

    final base = TerminalThemePresets.defaultTheme;
    return TerminalTheme(
      cursor: c('cursor', base.cursor),
      selection: c('selection', base.selection),
      foreground: c('foreground', base.foreground),
      background: c('background', base.background),
      black: c('black', base.black),
      red: c('red', base.red),
      green: c('green', base.green),
      yellow: c('yellow', base.yellow),
      blue: c('blue', base.blue),
      magenta: c('magenta', base.magenta),
      cyan: c('cyan', base.cyan),
      white: c('white', base.white),
      brightBlack: c('brightBlack', base.brightBlack),
      brightRed: c('brightRed', base.brightRed),
      brightGreen: c('brightGreen', base.brightGreen),
      brightYellow: c('brightYellow', base.brightYellow),
      brightBlue: c('brightBlue', base.brightBlue),
      brightMagenta: c('brightMagenta', base.brightMagenta),
      brightCyan: c('brightCyan', base.brightCyan),
      brightWhite: c('brightWhite', base.brightWhite),
      searchHitBackground: c('searchHitBackground', base.searchHitBackground),
      searchHitBackgroundCurrent:
          c('searchHitBackgroundCurrent', base.searchHitBackgroundCurrent),
      searchHitForeground: c('searchHitForeground', base.searchHitForeground),
    );
  }
}
