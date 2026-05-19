import 'dart:ui';

import 'package:flutter/widgets.dart';

const _kDefaultFontSize = 13.0;

const _kDefaultHeight = 1.2;

const _kDefaultFontFamily = 'monospace';

/// Distribute line-height leading evenly above and below each cell so the
/// selection highlight does not appear shifted relative to the glyphs.
const kTerminalTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
);

const _kDefaultFontFamilyFallback = [
  'Microsoft YaHei UI',   // Windows: clean CJK sans (terminal fallback)
  'Microsoft YaHei',
  'Menlo',
  'Monaco',
  'Consolas',
  'Cascadia Mono',
  'NSimSun',
  'MingLiU',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

class TerminalStyle {
  const TerminalStyle({
    this.fontSize = _kDefaultFontSize,
    this.height = _kDefaultHeight,
    this.fontFamily = _kDefaultFontFamily,
    this.fontFamilyFallback = _kDefaultFontFamilyFallback,
    this.fontWeight = FontWeight.normal,
  });

  factory TerminalStyle.fromTextStyle(TextStyle textStyle) {
    return TerminalStyle(
      fontSize: textStyle.fontSize ?? _kDefaultFontSize,
      height: textStyle.height ?? _kDefaultHeight,
      fontFamily: textStyle.fontFamily ??
          textStyle.fontFamilyFallback?.first ??
          _kDefaultFontFamily,
      fontFamilyFallback:
          textStyle.fontFamilyFallback ?? _kDefaultFontFamilyFallback,
    );
  }

  final double fontSize;

  final double height;

  final String fontFamily;

  final List<String> fontFamilyFallback;

  final FontWeight fontWeight;

  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
  }) {
    return TextStyle(
      fontSize: fontSize,
      height: height,
      leadingDistribution: TextLeadingDistribution.proportional,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: bold ? FontWeight.bold : fontWeight,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: underline ? TextDecoration.underline : TextDecoration.none,
    );
  }

  ParagraphStyle toParagraphStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
  }) {
    return toTextStyle(
      color: color,
      backgroundColor: backgroundColor,
      bold: bold,
      italic: italic,
      underline: underline,
    ).getParagraphStyle(textHeightBehavior: kTerminalTextHeightBehavior);
  }

  TerminalStyle copyWith({
    double? fontSize,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    FontWeight? fontWeight,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
      fontWeight: fontWeight ?? this.fontWeight,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalStyle &&
        other.fontSize == fontSize &&
        other.height == height &&
        other.fontFamily == fontFamily &&
        other.fontWeight == fontWeight &&
        _listEquals(other.fontFamilyFallback, fontFamilyFallback);
  }

  @override
  int get hashCode => Object.hash(
        fontSize,
        height,
        fontFamily,
        fontWeight,
        Object.hashAll(fontFamilyFallback),
      );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
