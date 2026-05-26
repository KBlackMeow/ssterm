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
  'Cascadia Mono',
  'Cascadia Code',
  'Consolas',
  'JetBrains Mono',
  'Menlo',
  'Monaco',
  'Courier New',
  'Liberation Mono',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'NSimSun',
  'MingLiU',
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
    this.boldFontWeight = FontWeight.bold,
    this.letterSpacing = 0,
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
      letterSpacing: textStyle.letterSpacing ?? 0,
    );
  }

  final double fontSize;

  final double height;

  final String fontFamily;

  final List<String> fontFamilyFallback;

  final FontWeight fontWeight;

  /// Font weight applied to cells with the ANSI bold (SGR 1) flag. Set to the
  /// same value as [fontWeight] to opt out of synthesized bold on platforms
  /// where the active font lacks a real bold cut (e.g. Consolas under Skia on
  /// Windows), where the synthesized strokes turn entire lines noticeably
  /// heavier than expected.
  final FontWeight boldFontWeight;

  /// Extra horizontal spacing between glyphs (negative tightens).
  final double letterSpacing;

  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool applyBoldWeight = true,
    bool italic = false,
    bool underline = false,
  }) {
    final ansiBold = bold && applyBoldWeight;
    return TextStyle(
      fontSize: fontSize,
      height: height,
      leadingDistribution: TextLeadingDistribution.proportional,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      letterSpacing: letterSpacing,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: ansiBold ? boldFontWeight : fontWeight,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: underline ? TextDecoration.underline : TextDecoration.none,
    );
  }

  ParagraphStyle toParagraphStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool applyBoldWeight = true,
    bool italic = false,
    bool underline = false,
  }) {
    return toTextStyle(
      color: color,
      backgroundColor: backgroundColor,
      bold: bold,
      applyBoldWeight: applyBoldWeight,
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
    FontWeight? boldFontWeight,
    double? letterSpacing,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
      fontWeight: fontWeight ?? this.fontWeight,
      boldFontWeight: boldFontWeight ?? this.boldFontWeight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalStyle &&
        other.fontSize == fontSize &&
        other.height == height &&
        other.fontFamily == fontFamily &&
        other.fontWeight == fontWeight &&
        other.boldFontWeight == boldFontWeight &&
        other.letterSpacing == letterSpacing &&
        _listEquals(other.fontFamilyFallback, fontFamilyFallback);
  }

  @override
  int get hashCode => Object.hash(
        fontSize,
        height,
        fontFamily,
        fontWeight,
        boldFontWeight,
        letterSpacing,
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
