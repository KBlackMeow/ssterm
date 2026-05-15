import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

/// Built-in terminal color schemes.
abstract final class TerminalThemePresets {
  static const iterm2 = TerminalTheme(
    cursor: Color(0xFFE0E0E0),
    selection: Color(0xFF4E6F91),
    foreground: Color(0xFFD4D4D4),
    background: Color(0xFF1C1C1C),
    black: Color(0xFF000000),
    white: Color(0xFFD4D4D4),
    red: Color(0xFFC91B00),
    green: Color(0xFF00C200),
    yellow: Color(0xFFC7C400),
    blue: Color(0xFF2472C8),
    magenta: Color(0xFFC930C7),
    cyan: Color(0xFF00C5C7),
    brightBlack: Color(0xFF757575),
    brightWhite: Color(0xFFFFFFFF),
    brightRed: Color(0xFFFF6E67),
    brightGreen: Color(0xFF5FFA68),
    brightYellow: Color(0xFFFFFC67),
    brightBlue: Color(0xFF6871FF),
    brightMagenta: Color(0xFFFF77FF),
    brightCyan: Color(0xFF60FDFF),
    searchHitBackground: Color(0xFFFF9F00),
    searchHitBackgroundCurrent: Color(0xFFFF6600),
    searchHitForeground: Color(0xFFFFFFFF),
  );

  static const dracula = TerminalTheme(
    cursor: Color(0xFFF8F8F2),
    selection: Color(0xFF44475A),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF282A36),
    black: Color(0xFF21222C),
    red: Color(0xFFFF5555),
    green: Color(0xFF50FA7B),
    yellow: Color(0xFFF1FA8C),
    blue: Color(0xFFBD93F9),
    magenta: Color(0xFFFF79C6),
    cyan: Color(0xFF8BE9FD),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF6272A4),
    brightRed: Color(0xFFFF6E6E),
    brightGreen: Color(0xFF69FF94),
    brightYellow: Color(0xFFFFF5A5),
    brightBlue: Color(0xFFD6ACFF),
    brightMagenta: Color(0xFFFF92DF),
    brightCyan: Color(0xFFA4FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFB86C),
    searchHitBackgroundCurrent: Color(0xFFFF79C6),
    searchHitForeground: Color(0xFF282A36),
  );

  static const oneDark = TerminalTheme(
    cursor: Color(0xFF528BFF),
    selection: Color(0xFF3E4451),
    foreground: Color(0xFFABB2BF),
    background: Color(0xFF282C34),
    black: Color(0xFF282C34),
    red: Color(0xFFE06C75),
    green: Color(0xFF98C379),
    yellow: Color(0xFFE5C07B),
    blue: Color(0xFF61AFEF),
    magenta: Color(0xFFC678DD),
    cyan: Color(0xFF56B6C2),
    white: Color(0xFFABB2BF),
    brightBlack: Color(0xFF5C6370),
    brightRed: Color(0xFFE06C75),
    brightGreen: Color(0xFF98C379),
    brightYellow: Color(0xFFE5C07B),
    brightBlue: Color(0xFF61AFEF),
    brightMagenta: Color(0xFFC678DD),
    brightCyan: Color(0xFF56B6C2),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFE5C07B),
    searchHitBackgroundCurrent: Color(0xFFD19A66),
    searchHitForeground: Color(0xFF282C34),
  );

  static const Map<String, TerminalTheme> all = {
    'iterm2': iterm2,
    'default': TerminalThemes.defaultTheme,
    'whiteOnBlack': TerminalThemes.whiteOnBlack,
    'dracula': dracula,
    'oneDark': oneDark,
  };

  static const labels = {
    'iterm2': 'iTerm2',
    'default': 'Default',
    'whiteOnBlack': 'White on Black',
    'dracula': 'Dracula',
    'oneDark': 'One Dark',
    'custom': 'Custom',
  };

  static String labelFor(String id) => labels[id] ?? id;
}
