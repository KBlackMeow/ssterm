import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import 'terminal_theme_codec.dart';
import 'terminal_theme_presets.dart';

/// User preferences for terminal appearance and cursor behavior.
class TerminalSettings {
  TerminalSettings({
    this.themePresetId = 'iterm2',
    TerminalTheme? customTheme,
    this.fontFamily = 'Monaco',
    this.fontSize = 13.5,
    this.lineHeight = 1.2,
    this.fontWeight = FontWeight.normal,
    this.cursorType = TerminalCursorType.block,
    this.cursorBlink = true,
    this.cursorBlinkPeriodMs = 530,
    this.textScale = 1.0,
  }) : customTheme = customTheme ?? TerminalThemePresets.iterm2;

  String themePresetId;
  TerminalTheme customTheme;

  String fontFamily;
  double fontSize;
  double lineHeight;
  FontWeight fontWeight;

  TerminalCursorType cursorType;
  bool cursorBlink;
  int cursorBlinkPeriodMs;
  double textScale;

  static const fontOptions = [
    'Monaco',
    'Menlo',
    'SF Mono',
    'JetBrains Mono',
    'Fira Code',
    'Consolas',
    'Courier New',
    'monospace',
  ];

  TerminalTheme resolveTheme() {
    if (themePresetId == 'custom') return customTheme;
    return TerminalThemePresets.all[themePresetId] ?? TerminalThemePresets.iterm2;
  }

  TerminalStyle toTerminalStyle() => TerminalStyle(
        fontSize: fontSize,
        height: lineHeight,
        fontFamily: fontFamily,
        fontWeight: fontWeight,
      );

  TerminalSettings copyWith({
    String? themePresetId,
    TerminalTheme? customTheme,
    String? fontFamily,
    double? fontSize,
    double? lineHeight,
    FontWeight? fontWeight,
    TerminalCursorType? cursorType,
    bool? cursorBlink,
    int? cursorBlinkPeriodMs,
    double? textScale,
  }) {
    return TerminalSettings(
      themePresetId: themePresetId ?? this.themePresetId,
      customTheme: customTheme ?? this.customTheme,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      fontWeight: fontWeight ?? this.fontWeight,
      cursorType: cursorType ?? this.cursorType,
      cursorBlink: cursorBlink ?? this.cursorBlink,
      cursorBlinkPeriodMs: cursorBlinkPeriodMs ?? this.cursorBlinkPeriodMs,
      textScale: textScale ?? this.textScale,
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

    return TerminalSettings(
      themePresetId: preset,
      customTheme: custom,
      fontFamily: json['fontFamily'] as String? ?? 'Monaco',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 13.5,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.2,
      fontWeight: _fontWeightFromString(json['fontWeight'] as String?),
      cursorType: _cursorTypeFromString(json['cursorType'] as String?),
      cursorBlink: json['cursorBlink'] as bool? ?? true,
      cursorBlinkPeriodMs: json['cursorBlinkPeriodMs'] as int? ?? 530,
      textScale: (json['textScale'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'themePreset': themePresetId,
        if (themePresetId == 'custom')
          'customTheme': TerminalThemeCodec.themeToJson(customTheme),
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'fontWeight': _fontWeightToString(fontWeight),
        'cursorType': _cursorTypeToString(cursorType),
        'cursorBlink': cursorBlink,
        'cursorBlinkPeriodMs': cursorBlinkPeriodMs,
        'textScale': textScale,
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
