import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';

/// Monospace faces used when measuring cell width so CJK fallbacks (which are
/// often proportional for Latin) do not inflate the cell grid.
const kLatinMonospaceFallback = [
  'Cascadia Mono',
  'Cascadia Code',
  'Consolas',
  'JetBrains Mono',
  'Fira Code',
  'Menlo',
  'Monaco',
  'SF Mono',
  'Courier New',
  'Liberation Mono',
  'monospace',
];

/// Measures the pixel size of one terminal cell for [style].
///
/// Cell width uses the configured font weight only (ANSI bold may clip slightly
/// rather than widening every column). Width is rounded to the nearest pixel;
/// height is ceiled so rows stay on whole-pixel boundaries.
Size measureCellSize(TerminalStyle style, TextScaler textScaler) {
  // Monospace cells are equal width; a broad ASCII sample averages cleanly.
  const test =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  final measureStyle = style.copyWith(
    fontFamilyFallback: kLatinMonospaceFallback,
  );

  final textStyle = measureStyle.toTextStyle();
  final builder = ParagraphBuilder(textStyle.getParagraphStyle());
  builder.pushStyle(textStyle.getTextStyle(textScaler: textScaler));
  builder.addText(test);

  final paragraph = builder.build();
  paragraph.layout(ParagraphConstraints(width: double.infinity));

  final width = paragraph.maxIntrinsicWidth / test.length;
  final height = paragraph.height;
  paragraph.dispose();

  return Size(width.roundToDouble(), height.ceilToDouble());
}
