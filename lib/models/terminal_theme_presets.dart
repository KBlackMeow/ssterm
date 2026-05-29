import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

/// Default terminal color schemes — one per mainstream terminal emulator,
/// taken from each project's shipping defaults rather than community remixes.
/// Sources noted on each scheme. Colors are intentionally not "improved" —
/// they match what users see opening a fresh install of each terminal.
abstract final class TerminalThemePresets {
  // ── Windows Terminal ───────────────────────────────────────────────────────

  /// Windows Terminal default since the app's first release.
  /// Source: microsoft/terminal repo, schemes.json → "Campbell".
  static const campbell = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    selection: Color(0xFF2F4C72),
    foreground: Color(0xFFCCCCCC),
    background: Color(0xFF0C0C0C),
    black: Color(0xFF0C0C0C),
    red: Color(0xFFC50F1F),
    green: Color(0xFF13A10E),
    yellow: Color(0xFFC19C00),
    blue: Color(0xFF0037DA),
    magenta: Color(0xFF881798),
    cyan: Color(0xFF3A96DD),
    white: Color(0xFFCCCCCC),
    brightBlack: Color(0xFF767676),
    brightRed: Color(0xFFE74856),
    brightGreen: Color(0xFF16C60C),
    brightYellow: Color(0xFFF9F1A5),
    brightBlue: Color(0xFF3B78FF),
    brightMagenta: Color(0xFFB4009E),
    brightCyan: Color(0xFF61D6D6),
    brightWhite: Color(0xFFF2F2F2),
    searchHitBackground: Color(0xFFF9F1A5),
    searchHitBackgroundCurrent: Color(0xFFF2F2F2),
    searchHitForeground: Color(0xFF0C0C0C),
  );

  /// Windows Terminal's PowerShell profile default (classic PS blue bg).
  /// Source: microsoft/terminal → "Campbell Powershell".
  static const campbellPowershell = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    selection: Color(0xFF2A4D6E),
    foreground: Color(0xFFCCCCCC),
    background: Color(0xFF012456),
    black: Color(0xFF0C0C0C),
    red: Color(0xFFC50F1F),
    green: Color(0xFF13A10E),
    yellow: Color(0xFFC19C00),
    blue: Color(0xFF0037DA),
    magenta: Color(0xFF881798),
    cyan: Color(0xFF3A96DD),
    white: Color(0xFFCCCCCC),
    brightBlack: Color(0xFF767676),
    brightRed: Color(0xFFE74856),
    brightGreen: Color(0xFF16C60C),
    brightYellow: Color(0xFFF9F1A5),
    brightBlue: Color(0xFF3B78FF),
    brightMagenta: Color(0xFFB4009E),
    brightCyan: Color(0xFF61D6D6),
    brightWhite: Color(0xFFF2F2F2),
    searchHitBackground: Color(0xFFF9F1A5),
    searchHitBackgroundCurrent: Color(0xFFF2F2F2),
    searchHitForeground: Color(0xFF012456),
  );

  // ── macOS Terminal.app ─────────────────────────────────────────────────────

  /// macOS Terminal.app's default profile (light).
  /// Source: Terminal.app → Preferences → Profiles → Basic.
  static const macTerminalBasic = TerminalTheme(
    cursor: Color(0xFF000000),
    selection: Color(0xFFB5D5FF),
    foreground: Color(0xFF000000),
    background: Color(0xFFFFFFFF),
    black: Color(0xFF000000),
    red: Color(0xFF990000),
    green: Color(0xFF00A600),
    yellow: Color(0xFF999900),
    blue: Color(0xFF0000B2),
    magenta: Color(0xFFB200B2),
    cyan: Color(0xFF00A6B2),
    white: Color(0xFFBFBFBF),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFE50000),
    brightGreen: Color(0xFF00D900),
    brightYellow: Color(0xFFE5E500),
    brightBlue: Color(0xFF0000FF),
    brightMagenta: Color(0xFFE500E5),
    brightCyan: Color(0xFF00E5E5),
    brightWhite: Color(0xFFE5E5E5),
    searchHitBackground: Color(0xFFFFFF00),
    searchHitBackgroundCurrent: Color(0xFFFFB000),
    searchHitForeground: Color(0xFF000000),
  );

  /// macOS Terminal.app's dark profile, popular as an alternate to Basic.
  /// Source: Terminal.app → Profiles → Pro.
  static const macTerminalPro = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    selection: Color(0xFF414141),
    foreground: Color(0xFFF2F2F2),
    background: Color(0xFF000000),
    black: Color(0xFF000000),
    red: Color(0xFFC23621),
    green: Color(0xFF25BC24),
    yellow: Color(0xFFADAD27),
    blue: Color(0xFF492EE1),
    magenta: Color(0xFFD338D3),
    cyan: Color(0xFF33BBC8),
    white: Color(0xFFCBCCCD),
    brightBlack: Color(0xFF818383),
    brightRed: Color(0xFFFC391F),
    brightGreen: Color(0xFF31E722),
    brightYellow: Color(0xFFEAEC23),
    brightBlue: Color(0xFF5833FF),
    brightMagenta: Color(0xFFF935F8),
    brightCyan: Color(0xFF14F0F0),
    brightWhite: Color(0xFFE9EBEB),
    searchHitBackground: Color(0xFFADAD27),
    searchHitBackgroundCurrent: Color(0xFFEAEC23),
    searchHitForeground: Color(0xFF000000),
  );

  // ── iTerm2 ─────────────────────────────────────────────────────────────────

  /// iTerm2's "Default" profile — the colors users get on first launch.
  /// Source: iTerm2 source / DefaultColors.itermcolors.
  static const iterm2Default = TerminalTheme(
    cursor: Color(0xFFC7C7C7),
    selection: Color(0xFFB4D5FE),
    foreground: Color(0xFFC7C7C7),
    background: Color(0xFF000000),
    black: Color(0xFF000000),
    red: Color(0xFFC91B00),
    green: Color(0xFF00C200),
    yellow: Color(0xFFC7C400),
    blue: Color(0xFF2225C7),
    magenta: Color(0xFFCA30C7),
    cyan: Color(0xFF00C5C7),
    white: Color(0xFFC7C7C7),
    brightBlack: Color(0xFF686868),
    brightRed: Color(0xFFFF6E67),
    brightGreen: Color(0xFF5FFA68),
    brightYellow: Color(0xFFFFFC67),
    brightBlue: Color(0xFF6871FF),
    brightMagenta: Color(0xFFFF77FF),
    brightCyan: Color(0xFF60FDFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFFC67),
    searchHitBackgroundCurrent: Color(0xFFFF9F00),
    searchHitForeground: Color(0xFF000000),
  );

  // ── VS Code integrated terminal ────────────────────────────────────────────

  /// VS Code's Dark+ theme — the default integrated terminal palette.
  /// Source: microsoft/vscode → src/.../theme.ts, terminal.ansi* defaults.
  static const vscodeDark = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    selection: Color(0xFF264F78),
    foreground: Color(0xFFCCCCCC),
    background: Color(0xFF1E1E1E),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF0DBC79),
    yellow: Color(0xFFE5E510),
    blue: Color(0xFF2472C8),
    magenta: Color(0xFFBC3FBC),
    cyan: Color(0xFF11A8CD),
    white: Color(0xFFE5E5E5),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFF14C4C),
    brightGreen: Color(0xFF23D18B),
    brightYellow: Color(0xFFF5F543),
    brightBlue: Color(0xFF3B8EEA),
    brightMagenta: Color(0xFFD670D6),
    brightCyan: Color(0xFF29B8DB),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF6E5F00),
    searchHitBackgroundCurrent: Color(0xFFEA5C00),
    searchHitForeground: Color(0xFFFFFFFF),
  );

  /// VS Code's Light+ theme integrated terminal palette.
  /// Source: same as [vscodeDark] but the light defaults.
  static const vscodeLight = TerminalTheme(
    cursor: Color(0xFF000000),
    selection: Color(0xFFADD6FF),
    foreground: Color(0xFF333333),
    background: Color(0xFFFFFFFF),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF00BC00),
    yellow: Color(0xFF949800),
    blue: Color(0xFF0451A5),
    magenta: Color(0xFFBC05BC),
    cyan: Color(0xFF0598BC),
    white: Color(0xFF555555),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFCD3131),
    brightGreen: Color(0xFF14CE14),
    brightYellow: Color(0xFFB5BA00),
    brightBlue: Color(0xFF0451A5),
    brightMagenta: Color(0xFFBC05BC),
    brightCyan: Color(0xFF0598BC),
    brightWhite: Color(0xFFA5A5A5),
    searchHitBackground: Color(0xFFFFE564),
    searchHitBackgroundCurrent: Color(0xFFEA5C00),
    searchHitForeground: Color(0xFF000000),
  );

  // ── GNOME Terminal ─────────────────────────────────────────────────────────

  /// Ubuntu's iconic aubergine terminal — gnome-terminal's "Ubuntu" profile.
  /// Background and accent track the official Ubuntu/Yaru defaults; the rest
  /// of the palette is Tango with the ANSI green retuned to Yaru green
  /// (#4DA859) so it reads as a clean green instead of Tango's olive cast.
  static const ubuntu = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    // Yaru accent (Ubuntu orange) — matches the system selection highlight.
    selection: Color(0xFFE95420),
    foreground: Color(0xFFFFFFFF),
    // The famous "aubergine" background, RGB(48, 10, 36).
    background: Color(0xFF300A24),
    black: Color(0xFF2E3436),
    red: Color(0xFFCC0000),
    // Yaru green instead of Tango's #4E9A06 — same darkness, less yellow.
    green: Color(0xFF4DA859),
    yellow: Color(0xFFC4A000),
    blue: Color(0xFF3465A4),
    magenta: Color(0xFF75507B),
    cyan: Color(0xFF06989A),
    white: Color(0xFFD3D7CF),
    brightBlack: Color(0xFF555753),
    brightRed: Color(0xFFEF2929),
    brightGreen: Color(0xFF8AE234),
    brightYellow: Color(0xFFFCE94F),
    brightBlue: Color(0xFF729FCF),
    brightMagenta: Color(0xFFAD7FA8),
    brightCyan: Color(0xFF34E2E2),
    brightWhite: Color(0xFFEEEEEC),
    searchHitBackground: Color(0xFFFCE94F),
    searchHitBackgroundCurrent: Color(0xFFE95420),
    searchHitForeground: Color(0xFF300A24),
  );

  /// GNOME Terminal's Tango Dark palette — the GNOME desktop default.
  /// Source: GNOME/gnome-terminal → src/profile-preferences.ui.
  static const gnomeTango = TerminalTheme(
    cursor: Color(0xFFD3D7CF),
    selection: Color(0xFF555753),
    foreground: Color(0xFFD3D7CF),
    background: Color(0xFF2E3436),
    black: Color(0xFF2E3436),
    red: Color(0xFFCC0000),
    green: Color(0xFF4E9A06),
    yellow: Color(0xFFC4A000),
    blue: Color(0xFF3465A4),
    magenta: Color(0xFF75507B),
    cyan: Color(0xFF06989A),
    white: Color(0xFFD3D7CF),
    brightBlack: Color(0xFF555753),
    brightRed: Color(0xFFEF2929),
    brightGreen: Color(0xFF8AE234),
    brightYellow: Color(0xFFFCE94F),
    brightBlue: Color(0xFF729FCF),
    brightMagenta: Color(0xFFAD7FA8),
    brightCyan: Color(0xFF34E2E2),
    brightWhite: Color(0xFFEEEEEC),
    searchHitBackground: Color(0xFFFCE94F),
    searchHitBackgroundCurrent: Color(0xFFC4A000),
    searchHitForeground: Color(0xFF2E3436),
  );

  /// Default theme ID — VS Code Dark+ is the palette most developers
  /// encounter daily through the integrated terminal.
  static const String defaultId = 'vscodeDark';
  static TerminalTheme get defaultTheme => vscodeDark;

  /// Theme ID → TerminalTheme. Order here drives the picker order in the UI.
  static const Map<String, TerminalTheme> all = {
    'vscodeDark': vscodeDark,
    'vscodeLight': vscodeLight,
    'campbell': campbell,
    'campbellPowershell': campbellPowershell,
    'iterm2Default': iterm2Default,
    'macTerminalBasic': macTerminalBasic,
    'macTerminalPro': macTerminalPro,
    'ubuntu': ubuntu,
    'gnomeTango': gnomeTango,
  };

  static const labels = {
    'vscodeDark': 'Dark+ (VS Code)',
    'vscodeLight': 'Light+ (VS Code)',
    'campbell': 'Campbell (Windows Terminal)',
    'campbellPowershell': 'Campbell PowerShell',
    'iterm2Default': 'Default (iTerm2)',
    'macTerminalBasic': 'Basic (macOS Terminal)',
    'macTerminalPro': 'Pro (macOS Terminal)',
    'ubuntu': 'Ubuntu',
    'gnomeTango': 'Tango (GNOME Terminal)',
    'custom': 'Custom',
  };

  static String labelFor(String id) => labels[id] ?? id;
}
