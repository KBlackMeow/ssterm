import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import 'crt_settings.dart';
import 'terminal_theme_codec.dart';
import 'terminal_theme_presets.dart';

/// User preferences for terminal appearance and cursor behavior.
class TerminalSettings {
  /// Platform-aware default monospace face.
  static String get defaultFontFamily {
    if (Platform.isWindows) return 'Consolas';
    if (Platform.isMacOS) return 'Monaco';
    return 'JetBrains Mono';
  }

  /// Fallback face for CJK and other non-Latin glyphs in the terminal.
  static String get defaultCjkFontFamily {
    if (Platform.isWindows) return 'Microsoft YaHei UI';
    if (Platform.isMacOS) return 'PingFang SC';
    return 'Noto Sans Mono CJK SC';
  }

  TerminalSettings({
    this.themePresetId = 'iterm2',
    TerminalTheme? customTheme,
    String? fontFamily,
    String? cjkFontFamily,
    this.fontSize = 13.5,
    this.lineHeight = 1.2,
    this.fontWeight = FontWeight.normal,
    this.cursorType = TerminalCursorType.block,
    this.cursorBlink = true,
    this.cursorBlinkPeriodMs = 530,
    this.textScale = 1.0,
    this.wallpaperId,
    this.wallpaperEnabled = false,
    this.wallpaperOpacity = 1.0,
    this.wallpaperBlur = 12.0,
    this.backgroundOpacity = 0.88,
    CrtSettings? crt,
  })  : fontFamily = fontFamily ?? defaultFontFamily,
        cjkFontFamily = cjkFontFamily ?? defaultCjkFontFamily,
        customTheme = customTheme ?? TerminalThemePresets.iterm2,
        crt = crt ?? const CrtSettings();

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

  CrtSettings crt;

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

  static List<String> get fontOptions {
    if (Platform.isWindows) {
      return const [
        'Consolas',
        'JetBrains Mono',
        'Cascadia Mono',
        'Cascadia Code',
        'Fira Code',
        'Courier New',
        'Monaco',
        'monospace',
      ];
    }
    return const [
      'Monaco',
      'SF Mono',
      'Menlo',
      'JetBrains Mono',
      'Fira Code',
      'Consolas',
      'Courier New',
      'monospace',
    ];
  }

  /// Resolves a persisted [savedFont] to a face available on this platform.
  static String resolveFontFamily(String? savedFont) {
    if (savedFont == null) return defaultFontFamily;

    // Previous Windows builds defaulted to Cascadia Mono / upgraded Monaco.
    if (Platform.isWindows &&
        (savedFont == 'Monaco' || savedFont == 'Cascadia Mono')) {
      return defaultFontFamily;
    }

    if (fontOptions.contains(savedFont)) return savedFont;
    return defaultFontFamily;
  }

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
    // Latin monospace faces must come before CJK fallbacks. When the primary
    // font is missing, Flutter walks this list for every glyph — putting CJK
    // first makes Windows render ASCII in proportional YaHei/SimSun with huge
    // letter spacing inside fixed-width cells.
    final latinMono = <String>[
      if (Platform.isWindows) ...[
        'Consolas',
        'Cascadia Mono',
        'Cascadia Code',
      ],
      if (Platform.isMacOS) ...[
        'Menlo',
        'Monaco',
        'SF Mono',
      ],
      'JetBrains Mono',
      'Fira Code',
      'Courier New',
      'Liberation Mono',
      'monospace',
    ];

    if (Platform.isWindows) {
      return [
        ...latinMono,
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
        ...latinMono,
        cjkFontFamily,
        'PingFang SC',
        'Hiragino Sans GB',
        'Noto Sans Mono CJK SC',
        'Noto Color Emoji',
        'sans-serif',
      ];
    }
    return [
      ...latinMono,
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

  static TerminalTheme _brightenText(TerminalTheme t) {
    Color lift(Color c, double amount) =>
        Color.lerp(c, const Color(0xFFFFFFFF), amount)!;

    return TerminalTheme(
      cursor: lift(t.cursor, _kTextLift),
      selection: t.selection,
      foreground: lift(t.foreground, _kTextLift),
      background: t.background,
      black: t.black,
      red: lift(t.red, _kAnsiLift),
      green: lift(t.green, _kAnsiLift),
      yellow: lift(t.yellow, _kAnsiLift),
      blue: lift(t.blue, _kAnsiLift),
      magenta: lift(t.magenta, _kAnsiLift),
      cyan: lift(t.cyan, _kAnsiLift),
      white: lift(t.white, _kTextLift),
      brightBlack: lift(t.brightBlack, _kTextLift),
      brightRed: lift(t.brightRed, _kAnsiLift),
      brightGreen: lift(t.brightGreen, _kAnsiLift),
      brightYellow: lift(t.brightYellow, _kAnsiLift),
      brightBlue: lift(t.brightBlue, _kAnsiLift),
      brightMagenta: lift(t.brightMagenta, _kAnsiLift),
      brightCyan: lift(t.brightCyan, _kAnsiLift),
      brightWhite: lift(t.brightWhite, _kTextLift * 0.5),
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
    CrtSettings? crt,
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
      crt: crt ?? this.crt,
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
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 13.5,
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
      crt: CrtSettings.fromJson(json['crt'] as Map<String, dynamic>?),
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
        'crt': crt.toJson(),
      };

  static FontWeight _fontWeightFromString(String? s) => switch (s) {
        'medium' => FontWeight.w500,
        'semibold' => FontWeight.w600,
        'bold' => FontWeight.bold,
        _ => FontWeight.normal,
      };

  static String _fontWeightToString(FontWeight w) {
    if (w == FontWeight.bold) return 'bold';
    if (w == FontWeight.w600) return 'semibold';
    if (w == FontWeight.w500) return 'medium';
    return 'normal';
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
