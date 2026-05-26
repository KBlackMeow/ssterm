import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import 'terminal_theme_codec.dart';
import 'terminal_theme_presets.dart';

/// User preferences for terminal appearance and cursor behavior.
class TerminalSettings {
  /// Defaults match each platform's native terminal conventions:
  ///   Windows → Cascadia Mono  (Windows Terminal default, ships with Win10
  ///                             1809+/Win11, native ➜/Powerline glyphs)
  ///   macOS   → Monaco          (classic Mac terminal face, system font)
  ///   Linux   → JetBrainsMono   (bundled — distros vary too much to rely on)
  /// Family names must match the font's actual registered family
  /// (e.g. pubspec's `family:` for JetBrainsMono).
  static String get defaultFontFamily {
    if (Platform.isWindows) return 'Cascadia Mono';
    if (Platform.isMacOS) return 'Monaco';
    return 'JetBrainsMono';
  }

  /// Fallback face for CJK and other non-Latin glyphs in the terminal.
  static String get defaultCjkFontFamily {
    if (Platform.isWindows) return 'Microsoft YaHei UI';
    if (Platform.isMacOS) return 'PingFang SC';
    return 'Noto Sans Mono CJK SC';
  }

  /// Matches each platform's native terminal default:
  ///   Windows → 12  (Windows Terminal default)
  ///   macOS   → 12  (matches VS Code on macOS; Terminal.app uses 11)
  ///   Linux   → 14
  static double get defaultFontSize => Platform.isLinux ? 14.0 : 12.0;

  /// Windows tightens by 0.2px — Consolas reads loose in Skia (no ClearType)
  /// at small sizes. The painter's per-glyph adaptive clip (see
  /// packages/xterm/lib/src/ui/painter.dart) handles fallback glyphs wider
  /// than the cell, so this tracking adjustment no longer risks clipping.
  static double get defaultLetterSpacing => Platform.isWindows ? -0.2 : 0;

  TerminalSettings({
    this.themePresetId = 'iterm2',
    TerminalTheme? customTheme,
    String? fontFamily,
    String? cjkFontFamily,
    double? fontSize,
    this.lineHeight = 1.2,
    this.fontWeight = FontWeight.w400,
    this.cursorType = TerminalCursorType.block,
    this.cursorBlink = true,
    this.cursorBlinkPeriodMs = 530,
    this.textScale = 1.0,
    this.wallpaperId,
    this.wallpaperEnabled = false,
    this.wallpaperOpacity = 1.0,
    this.wallpaperBlur = 12.0,
    this.backgroundOpacity = 0.88,
  })  : fontFamily = fontFamily ?? defaultFontFamily,
        cjkFontFamily = cjkFontFamily ?? defaultCjkFontFamily,
        fontSize = fontSize ?? defaultFontSize,
        customTheme = customTheme ?? TerminalThemePresets.iterm2;

  String themePresetId;
  TerminalTheme customTheme;

  String fontFamily;
  String cjkFontFamily;
  double fontSize;
  double lineHeight;
  FontWeight fontWeight;

  TerminalCursorType cursorType;
  bool cursorBlink;
  int cursorBlinkPeriodMs;
  double textScale;

  /// Filename under `~/.ssterm/wallpapers/`, or null when none chosen.
  String? wallpaperId;
  /// When false, [wallpaperId] is kept but wallpaper is not shown.
  bool wallpaperEnabled;
  double wallpaperOpacity;
  /// Gaussian blur radius (sigma) for the wallpaper, 0 = none.
  double wallpaperBlur;
  /// Terminal cell background opacity when a wallpaper is set (0 = transparent).
  double backgroundOpacity;

  bool get hasWallpaper =>
      wallpaperEnabled && wallpaperId != null && wallpaperId!.isNotEmpty;

  double get effectiveBackgroundOpacity =>
      hasWallpaper ? backgroundOpacity.clamp(0.0, 1.0) : 1.0;

  /// Tab bar strip + terminal backdrop — same as [TerminalView]'s `Container`.
  Color get chromeBackground {
    final background = resolveTheme().background;
    if (hasWallpaper) {
      return background.withValues(alpha: effectiveBackgroundOpacity);
    }
    return background;
  }

  /// Selected tab button fill (pill only — not the tab bar strip).
  Color get chromeTabSelected {
    final base = resolveTheme().background;
    if (hasWallpaper) {
      return base.withValues(
        alpha: (effectiveBackgroundOpacity * 0.65).clamp(0.0, 1.0),
      );
    }
    // Opaque lift — alpha on a same-color bar is invisible without wallpaper.
    return _tabButtonTint(base, 0.16);
  }

  /// Unselected tab button fill — same hue, lower opacity.
  Color get chromeTabUnselected {
    final base = resolveTheme().background;
    if (hasWallpaper) {
      return base.withValues(
        alpha: (effectiveBackgroundOpacity * 0.28).clamp(0.0, 1.0),
      );
    }
    return _tabButtonTint(base, 0.08);
  }

  /// Lighten dark themes / darken light themes for visible tab pills.
  static Color _tabButtonTint(Color base, double amount) {
    final toward = base.computeLuminance() > 0.5
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    return Color.lerp(base, toward, amount.clamp(0.0, 1.0))!;
  }

  /// Terminal font is locked to the platform default. Saved values from
  /// older configs are intentionally ignored — the font picker was removed.
  static String resolveFontFamily(String? savedFont) => defaultFontFamily;

  static List<String> get cjkFontOptions {
    if (Platform.isWindows) {
      return const [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'SimSun',
        'NSimSun',
        'Noto Sans Mono CJK SC',
      ];
    }
    if (Platform.isMacOS) {
      return const [
        'PingFang SC',
        'STHeiti',
        'Noto Sans Mono CJK SC',
      ];
    }
    return const [
      'Noto Sans Mono CJK SC',
      'Noto Sans Mono CJK TC',
      'Noto Sans Mono CJK JP',
    ];
  }

  List<String> buildFontFamilyFallback() {
    // xterm hard-clips fallback glyphs to the cell width measured from the
    // primary font (see packages/xterm/lib/src/ui/painter.dart). When primary
    // is Consolas/Monaco and a glyph (e.g. ➜ U+279C) falls back to JetBrains
    // Mono, JBM's wider advance gets clipped on the right.
    //
    // Order matters: try metric-compatible faces first per platform, then
    // bundled JBM as a guaranteed-present last resort, then CJK + emoji.
    final bundledSymbols = fontFamily == 'JetBrainsMono'
        ? const <String>[]
        : const ['JetBrainsMono'];

    if (Platform.isWindows) {
      return [
        // Cascadia Code shares Cascadia Mono's metrics (same family designed
        // together) and adds programming-ligature glyphs as backup. Consolas
        // is kept as a last resort for any glyph both Cascadia faces lack.
        if (fontFamily != 'Cascadia Code') 'Cascadia Code',
        if (fontFamily != 'Cascadia Mono') 'Cascadia Mono',
        'Consolas',
        ...bundledSymbols,
        cjkFontFamily,
        if (cjkFontFamily != 'Microsoft YaHei') 'Microsoft YaHei',
        'NSimSun',
        'SimSun',
        'Noto Sans Mono CJK SC',
        'Noto Color Emoji',
        'Noto Sans Symbols',
        'sans-serif',
      ];
    }
    if (Platform.isMacOS) {
      return [
        // Menlo and SF Mono share Monaco's cell metrics on macOS, so symbol
        // fallback through them avoids clipping. Both are preinstalled.
        'Menlo',
        'SF Mono',
        ...bundledSymbols,
        cjkFontFamily,
        'PingFang SC',
        'Hiragino Sans GB',
        'Noto Sans Mono CJK SC',
        'Noto Color Emoji',
        'sans-serif',
      ];
    }
    return [
      ...bundledSymbols,
      cjkFontFamily,
      'Noto Sans Mono CJK SC',
      'Noto Sans Mono CJK TC',
      'Noto Sans Mono CJK JP',
      'Noto Color Emoji',
      'sans-serif',
    ];
  }

  TerminalTheme resolveTheme() {
    final base = themePresetId == 'custom'
        ? customTheme
        : TerminalThemePresets.all[themePresetId] ?? TerminalThemePresets.iterm2;
    return _brightenText(base);
  }

  static const _kTextLift = 0.06;
  static const _kAnsiLift = 0.04;
  static const _kWindowsTextLift = 0.02;
  static const _kWindowsAnsiLift = 0.015;

  static TerminalTheme _brightenText(TerminalTheme t) {
    final textLift = Platform.isWindows ? _kWindowsTextLift : _kTextLift;
    final ansiLift = Platform.isWindows ? _kWindowsAnsiLift : _kAnsiLift;

    Color lift(Color c, double amount) =>
        Color.lerp(c, const Color(0xFFFFFFFF), amount)!;

    return TerminalTheme(
      cursor: lift(t.cursor, textLift),
      selection: t.selection,
      foreground: lift(t.foreground, textLift),
      background: t.background,
      black: t.black,
      red: lift(t.red, ansiLift),
      green: lift(t.green, ansiLift),
      yellow: lift(t.yellow, ansiLift),
      blue: lift(t.blue, ansiLift),
      magenta: lift(t.magenta, ansiLift),
      cyan: lift(t.cyan, ansiLift),
      white: lift(t.white, textLift),
      brightBlack: lift(t.brightBlack, textLift),
      brightRed: lift(t.brightRed, ansiLift),
      brightGreen: lift(t.brightGreen, ansiLift),
      brightYellow: lift(t.brightYellow, ansiLift),
      brightBlue: lift(t.brightBlue, ansiLift),
      brightMagenta: lift(t.brightMagenta, ansiLift),
      brightCyan: lift(t.brightCyan, ansiLift),
      brightWhite: lift(t.brightWhite, textLift * 0.5),
      searchHitBackground: t.searchHitBackground,
      searchHitBackgroundCurrent: t.searchHitBackgroundCurrent,
      searchHitForeground: t.searchHitForeground,
    );
  }

  TerminalStyle toTerminalStyle() => TerminalStyle(
        fontSize: fontSize,
        height: lineHeight,
        fontFamily: fontFamily,
        fontFamilyFallback: buildFontFamilyFallback(),
        fontWeight: fontWeight,
        // Windows: Consolas and most system monospaces lack a real bold cut,
        // so Skia synthesizes bold by thickening strokes. Combined with
        // prompt SGR-1 residue from plugin-heavy zsh setups under WSL, plain
        // command output (e.g. `ifconfig`) ends up rendered noticeably
        // heavier than on macOS. Match the bold weight to the regular weight
        // on Windows so the ANSI bold flag stops triggering synthesized bold.
        boldFontWeight: Platform.isWindows ? fontWeight : FontWeight.bold,
        letterSpacing: defaultLetterSpacing,
      );

  TerminalSettings copyWith({
    String? themePresetId,
    TerminalTheme? customTheme,
    String? fontFamily,
    String? cjkFontFamily,
    double? fontSize,
    double? lineHeight,
    FontWeight? fontWeight,
    TerminalCursorType? cursorType,
    bool? cursorBlink,
    int? cursorBlinkPeriodMs,
    double? textScale,
    String? wallpaperId,
    bool clearWallpaper = false,
    bool? wallpaperEnabled,
    double? wallpaperOpacity,
    double? wallpaperBlur,
    double? backgroundOpacity,
  }) {
    return TerminalSettings(
      themePresetId: themePresetId ?? this.themePresetId,
      customTheme: customTheme ?? this.customTheme,
      fontFamily: fontFamily ?? this.fontFamily,
      cjkFontFamily: cjkFontFamily ?? this.cjkFontFamily,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      fontWeight: fontWeight ?? this.fontWeight,
      cursorType: cursorType ?? this.cursorType,
      cursorBlink: cursorBlink ?? this.cursorBlink,
      cursorBlinkPeriodMs: cursorBlinkPeriodMs ?? this.cursorBlinkPeriodMs,
      textScale: textScale ?? this.textScale,
      wallpaperId: clearWallpaper ? null : (wallpaperId ?? this.wallpaperId),
      wallpaperEnabled: clearWallpaper
          ? false
          : (wallpaperEnabled ?? this.wallpaperEnabled),
      wallpaperOpacity: wallpaperOpacity ?? this.wallpaperOpacity,
      wallpaperBlur: wallpaperBlur ?? this.wallpaperBlur,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    );
  }

  void applyPreset(String id) {
    themePresetId = id;
    if (id != 'custom') {
      customTheme = TerminalThemePresets.all[id] ?? TerminalThemePresets.iterm2;
    }
  }

  void setCustomColor(String key, Color color) {
    themePresetId = 'custom';
    final j = TerminalThemeCodec.themeToJson(customTheme);
    j[key] = TerminalThemeCodec.colorToJson(color);
    customTheme = TerminalThemeCodec.themeFromJson(j);
  }

  static TerminalSettings fromJson(Map<String, dynamic>? json) {
    if (json == null) return TerminalSettings();
    final preset = json['themePreset'] as String? ?? 'iterm2';
    TerminalTheme custom = TerminalThemePresets.iterm2;
    if (json['customTheme'] is Map<String, dynamic>) {
      custom = TerminalThemeCodec.themeFromJson(
        json['customTheme'] as Map<String, dynamic>,
      );
    } else if (preset != 'custom') {
      custom = TerminalThemePresets.all[preset] ?? TerminalThemePresets.iterm2;
    }

    final savedFont = json['fontFamily'] as String?;
    final fontFamily = resolveFontFamily(savedFont);

    return TerminalSettings(
      themePresetId: preset,
      customTheme: custom,
      fontFamily: fontFamily,
      cjkFontFamily:
          json['cjkFontFamily'] as String? ?? defaultCjkFontFamily,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? defaultFontSize,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.2,
      fontWeight: _fontWeightFromString(json['fontWeight'] as String?),
      cursorType: _cursorTypeFromString(json['cursorType'] as String?),
      cursorBlink: json['cursorBlink'] as bool? ?? true,
      cursorBlinkPeriodMs: json['cursorBlinkPeriodMs'] as int? ?? 530,
      textScale: (json['textScale'] as num?)?.toDouble() ?? 1.0,
      wallpaperId: json['wallpaperId'] as String?,
      wallpaperEnabled: json['wallpaperEnabled'] as bool? ??
          (json['wallpaperId'] != null &&
              (json['wallpaperId'] as String).isNotEmpty),
      wallpaperOpacity: (json['wallpaperOpacity'] as num?)?.toDouble() ?? 1.0,
      wallpaperBlur: (json['wallpaperBlur'] as num?)?.toDouble() ?? 12.0,
      backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble() ?? 0.88,
    );
  }

  Map<String, dynamic> toJson() => {
        'themePreset': themePresetId,
        if (themePresetId == 'custom')
          'customTheme': TerminalThemeCodec.themeToJson(customTheme),
        'fontFamily': fontFamily,
        'cjkFontFamily': cjkFontFamily,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'fontWeight': _fontWeightToString(fontWeight),
        'cursorType': _cursorTypeToString(cursorType),
        'cursorBlink': cursorBlink,
        'cursorBlinkPeriodMs': cursorBlinkPeriodMs,
        'textScale': textScale,
        if (wallpaperId != null) 'wallpaperId': wallpaperId,
        'wallpaperEnabled': wallpaperEnabled,
        'wallpaperOpacity': wallpaperOpacity,
        'wallpaperBlur': wallpaperBlur,
        'backgroundOpacity': backgroundOpacity,
      };

  static FontWeight _fontWeightFromString(String? s) => switch (s) {
        'light' => FontWeight.w300,
        'medium' => FontWeight.w500,
        'semibold' => FontWeight.w600,
        'bold' => FontWeight.bold,
        _ => FontWeight.w400,
      };

  static String _fontWeightToString(FontWeight w) {
    if (w == FontWeight.bold) return 'bold';
    if (w == FontWeight.w600) return 'semibold';
    if (w == FontWeight.w500) return 'medium';
    if (w == FontWeight.w400) return 'normal';
    return 'light';
  }

  static TerminalCursorType _cursorTypeFromString(String? s) =>
      switch (s) {
        'underline' => TerminalCursorType.underline,
        'verticalBar' => TerminalCursorType.verticalBar,
        _ => TerminalCursorType.block,
      };

  static String _cursorTypeToString(TerminalCursorType t) => switch (t) {
        TerminalCursorType.underline => 'underline',
        TerminalCursorType.verticalBar => 'verticalBar',
        TerminalCursorType.block => 'block',
      };
}
