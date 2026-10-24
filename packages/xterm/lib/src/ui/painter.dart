import 'package:flutter/painting.dart';

import 'package:xterm/src/ui/char_metrics.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);
  final _lineParagraphCache = ParagraphCache(512);

  TextStyle? _plainAsciiStyle;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _lineParagraphCache.clear();
    _plainAsciiStyle = null;
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _lineParagraphCache.clear();
    _plainAsciiStyle = null;
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _lineParagraphCache.clear();
    _plainAsciiStyle = null;
  }

  Size _measureCharSize() {
    return measureCellSize(_textStyle, _textScaler);
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _lineParagraphCache.clear();
    _plainAsciiStyle = null;
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        final thickness = (_cellSize.height * 0.12).clamp(2.0, 4.0);
        paint.style = PaintingStyle.fill;
        canvas.drawRect(
          Rect.fromLTWH(
            offset.dx,
            offset.dy + _cellSize.height - thickness,
            _cellSize.width,
            thickness,
          ),
          paint,
        );
        return;
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy),
          Offset(offset.dx, offset.dy + _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    if (_paintPlainAsciiLine(canvas, offset, line)) return;

    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);

      paintCellBackground(canvas, cellOffset, cellData);

      if (charWidth == 2) {
        i++;
      }
    }

    // Finish all backgrounds before drawing ink that can overhang into the
    // next column. Otherwise that column's background erases italic strokes.
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);
      paintCellForeground(canvas, cellOffset, cellData);
      paintCellUnderline(canvas, cellOffset, cellData);

      if (charWidth == 2) {
        i++;
      }
    }
  }

  bool _paintPlainAsciiLine(Canvas canvas, Offset offset, BufferLine line) {
    // Laying out a paragraph is only worthwhile once it replaces enough
    // individual cell draws. Keep short text on the exact cell paint path.
    final text = StringBuffer();
    var lastContent = 0;
    for (var i = 0; i < line.length; i++) {
      if (line.getForeground(i) != 0 ||
          line.getBackground(i) != 0 ||
          line.getAttributes(i) != 0) {
        return false;
      }
      final content = line.getContent(i);
      final codepoint = content & CellContent.codepointMask;
      if (codepoint == 0) {
        text.write(' ');
      } else if (codepoint >= 0x20 &&
          codepoint <= 0x7e &&
          content >> CellContent.widthShift == 1) {
        text.writeCharCode(codepoint);
        lastContent = i + 1;
      } else {
        return false;
      }
    }
    if (lastContent < 16) return false;
    final content = text.toString().substring(0, lastContent);
    final style = _plainAsciiStyle ??= _makePlainAsciiStyle();
    final key = ('plainAsciiLine', content, _textScaler);
    final paragraph = _lineParagraphCache.getLayoutFromCache(key) ??
        _lineParagraphCache.performAndCacheLayout(
          content,
          style,
          _textScaler,
          key,
        );
    canvas.drawParagraph(paragraph, offset);
    return true;
  }

  TextStyle _makePlainAsciiStyle() {
    final baseStyle = _textStyle.toTextStyle(
      color: resolveForegroundColor(0),
    );
    final advance = _paragraphCache.performAndCacheLayout(
      '0',
      baseStyle,
      _textScaler,
      ('plainAsciiAdvance', _textScaler),
    ).maxIntrinsicWidth;
    return baseStyle.copyWith(
      letterSpacing: _textStyle.letterSpacing + _cellSize.width - advance,
      fontFeatures: const [
        FontFeature.disable('liga'),
        FontFeature.disable('calt'),
      ],
    );
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
    paintCellUnderline(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final charWidth = cellData.content >> CellContent.widthShift;

    // Block elements (U+2580–U+259F): render directly as canvas shapes so they
    // tile seamlessly regardless of font metrics or line-height settings.
    if (charCode >= 0x2580 && charCode <= 0x259F) {
      final cellFlags = cellData.flags;
      var color = cellFlags & CellFlags.inverse == 0
          ? resolveForegroundColor(cellData.foreground)
          : resolveBackgroundColor(cellData.background);
      if (cellFlags & CellFlags.faint != 0) {
        color = color.withValues(alpha: 0.5);
      }
      _paintBlockElement(canvas, offset, charCode, color);
      return;
    }

    // Glyph cache ignores underline; underline is drawn in [paintCellUnderline].
    // Keep the complete style/content tuple as the map key. A bare combined
    // hash is not unique: animated, colour-shifting terminal UIs create enough
    // glyph variants to collide, after which the cached paragraph for a
    // different character can be painted (for example an `i` in place of a
    // spinner symbol) until the font cache is cleared.
    final cacheKey = (
      foreground: cellData.foreground,
      background: cellData.background,
      flags: cellData.flags & ~CellFlags.underline,
      content: cellData.content,
      textScaler: _textScaler,
    );
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;

      var color = cellFlags & CellFlags.inverse == 0
          ? resolveForegroundColor(cellData.foreground)
          : resolveBackgroundColor(cellData.background);

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withValues(alpha: 0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        // Wide glyphs (CJK, emoji) use fallback fonts that often lack a real
        // bold cut; Flutter then synthesizes bold and strokes look too heavy.
        applyBoldWeight: charWidth < 2,
        italic: cellFlags & CellFlags.italic != 0,
      );

      paragraph = _paragraphCache.performAndCacheLayout(
        String.fromCharCode(charCode),
        style.copyWith(
            leadingDistribution: TextLeadingDistribution.proportional),
        _textScaler,
        cacheKey,
      );
    }

    // Italic ink can extend beyond either side of its advance width (for
    // example JetBrains Mono `%`). Paragraph intrinsic width measures advance,
    // not ink bounds, so a fixed per-cell bleed still cuts off strokes. Keep
    // italic ink intact; the terminal viewport supplies the outer clip.
    if (cellData.flags & CellFlags.italic != 0) {
      canvas.drawParagraph(paragraph, offset);
      return;
    }

    // Preserve the existing allowance for upright fallback glyphs wider than
    // the grid, and antialiased leading edges after device-pixel snapping.
    final cellClip = _cellSize.width * (charWidth >= 2 ? 2 : 1);
    final glyphWidth = paragraph.maxIntrinsicWidth;
    const glyphBleedLeft = 1.0;
    final clipWidth = glyphWidth > cellClip ? glyphWidth : cellClip;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
        offset.dx - glyphBleedLeft,
        offset.dy,
        clipWidth + glyphBleedLeft,
        _cellSize.height,
      ),
    );
    canvas.drawParagraph(paragraph, offset);
    canvas.restore();
  }

  /// Renders a Unicode Block Element (U+2580–U+259F) as filled canvas
  /// rectangles. This guarantees pixel-perfect cell coverage with no font
  /// metric or line-height artifacts.
  void _paintBlockElement(
      Canvas canvas, Offset offset, int charCode, Color color) {
    final w = _cellSize.width;
    final h = _cellSize.height;
    final x = offset.dx;
    final y = offset.dy;
    final hw = w / 2;
    final hh = h / 2;

    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;

    // Use floor for start coords and ceil for end coords so that fractional
    // midpoints (e.g. hw=4.5 for odd w=9) expand symmetrically: both the left
    // half (▌) and right half (▐) round to ceil(w/2)=5px rather than 5px vs 4px.
    // Full-cell edges (0, w, h) are integers so floor/ceil is a no-op there.
    void fill(double l, double t, double r, double b) {
      canvas.drawRect(
        Rect.fromLTRB(
          (x + l).floorToDouble(),
          (y + t).floorToDouble(),
          (x + r).ceilToDouble(),
          (y + b).ceilToDouble(),
        ),
        paint,
      );
    }

    switch (charCode) {
      case 0x2580:
        fill(0, 0, w, hh); // ▀ upper half
      case 0x2581:
        fill(0, h * 7 / 8, w, h); // ▁ lower 1/8
      case 0x2582:
        fill(0, h * 3 / 4, w, h); // ▂ lower 1/4
      case 0x2583:
        fill(0, h * 5 / 8, w, h); // ▃ lower 3/8
      case 0x2584:
        fill(0, hh, w, h); // ▄ lower half
      case 0x2585:
        fill(0, h * 3 / 8, w, h); // ▅ lower 5/8
      case 0x2586:
        fill(0, h / 4, w, h); // ▆ lower 3/4
      case 0x2587:
        fill(0, h / 8, w, h); // ▇ lower 7/8
      case 0x2588:
        fill(0, 0, w, h); // █ full
      case 0x2589:
        fill(0, 0, w * 7 / 8, h); // ▉ left 7/8
      case 0x258A:
        fill(0, 0, w * 3 / 4, h); // ▊ left 3/4
      case 0x258B:
        fill(0, 0, w * 5 / 8, h); // ▋ left 5/8
      case 0x258C:
        fill(0, 0, hw, h); // ▌ left half
      case 0x258D:
        fill(0, 0, w * 3 / 8, h); // ▍ left 3/8
      case 0x258E:
        fill(0, 0, w / 4, h); // ▎ left 1/4
      case 0x258F:
        fill(0, 0, w / 8, h); // ▏ left 1/8
      case 0x2590:
        fill(hw, 0, w, h); // ▐ right half
      // Shade chars: approximate as semi-transparent full-cell fill
      case 0x2591:
        paint.color = color.withValues(alpha: color.a * 0.25);
        fill(0, 0, w, h);
      case 0x2592:
        paint.color = color.withValues(alpha: color.a * 0.50);
        fill(0, 0, w, h);
      case 0x2593:
        paint.color = color.withValues(alpha: color.a * 0.75);
        fill(0, 0, w, h);
      case 0x2594:
        fill(0, 0, w, h / 8); // ▔ upper 1/8
      case 0x2595:
        fill(w * 7 / 8, 0, w, h); // ▕ right 1/8
      // Quadrant blocks
      case 0x2596:
        fill(0, hh, hw, h); // ▖ lower-left
      case 0x2597:
        fill(hw, hh, w, h); // ▗ lower-right
      case 0x2598:
        fill(0, 0, hw, hh); // ▘ upper-left
      case 0x2599: // ▙ upper-left + lower half
        fill(0, 0, hw, hh);
        fill(0, hh, w, h);
      case 0x259A: // ▚ upper-left + lower-right
        fill(0, 0, hw, hh);
        fill(hw, hh, w, h);
      case 0x259B: // ▛ upper half + lower-left
        fill(0, 0, w, hh);
        fill(0, hh, hw, h);
      case 0x259C: // ▜ upper half + lower-right
        fill(0, 0, w, hh);
        fill(hw, hh, w, h);
      case 0x259D:
        fill(hw, 0, w, hh); // ▝ upper-right
      case 0x259E: // ▞ upper-right + lower-left
        fill(hw, 0, w, hh);
        fill(0, hh, hw, h);
      case 0x259F: // ▟ upper-right + lower half
        fill(hw, 0, w, hh);
        fill(0, hh, w, h);
    }
  }

  /// Draws an underline (or overline) for the cell, respecting underline style.
  @pragma('vm:prefer-inline')
  void paintCellUnderline(Canvas canvas, Offset offset, CellData cellData) {
    final cellFlags = cellData.flags;
    final hasUnderline = cellFlags & CellFlags.underline != 0;
    final hasOverline = cellFlags & CellFlags.overline != 0;

    if (!hasUnderline && !hasOverline) return;

    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    var color = cellFlags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);

    if (cellData.underlineColor != 0) {
      color = _resolveUnderlineColor(cellData.underlineColor);
    }

    if (cellFlags & CellFlags.faint != 0) {
      color = color.withValues(alpha: 0.5);
    }

    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final lineWidth = _cellSize.width * (doubleWidth ? 2 : 1);

    if (hasOverline) {
      _drawStraightLine(canvas, offset.dx, offset.dy, lineWidth, color);
    }

    if (hasUnderline) {
      final ulStyle = (cellFlags & CellFlags.underlineStyleMask) >>
          CellFlags.underlineStyleShift;
      final y = offset.dy + _cellSize.height - 1;
      switch (ulStyle) {
        case 2: // double underline
          _drawStraightLine(canvas, offset.dx, y - 2, lineWidth, color);
          _drawStraightLine(canvas, offset.dx, y, lineWidth, color);
        case 3: // curly / wavy
          _drawWavyLine(canvas, offset.dx, y - 1, lineWidth, color);
        case 4: // dotted
          _drawDottedLine(canvas, offset.dx, y, lineWidth, color);
        case 5: // dashed
          _drawDashedLine(canvas, offset.dx, y, lineWidth, color);
        default: // 0, 1 — plain single underline
          _drawStraightLine(canvas, offset.dx, y, lineWidth, color);
      }
    }
  }

  void _drawStraightLine(
      Canvas canvas, double x, double y, double width, Color color) {
    canvas.drawLine(
      Offset(x, y),
      Offset(x + width, y),
      Paint()
        ..color = color
        ..strokeWidth = 1,
    );
  }

  /// Draws a wavy (sinusoidal) underline using quadratic bezier segments.
  void _drawWavyLine(
      Canvas canvas, double x, double y, double width, Color color) {
    final amplitude = (_cellSize.height * 0.10).clamp(1.0, 2.0);
    final period = (_cellSize.width * 2).clamp(4.0, 12.0);
    final path = Path();
    path.moveTo(x, y);
    var cx = x;
    var phase = true;
    while (cx < x + width) {
      final nextCx = (cx + period / 2).clamp(cx, x + width);
      final cy = phase ? y - amplitude : y + amplitude;
      path.quadraticBezierTo(cx + (nextCx - cx) / 2, cy, nextCx, y);
      cx = nextCx;
      phase = !phase;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawDottedLine(
      Canvas canvas, double x, double y, double width, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const step = 2.0;
    var cx = x + 0.5;
    while (cx < x + width) {
      canvas.drawCircle(Offset(cx, y), 0.5, paint);
      cx += step;
    }
  }

  void _drawDashedLine(
      Canvas canvas, double x, double y, double width, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final dashLen = _cellSize.width * 0.4;
    final gapLen = _cellSize.width * 0.2;
    var cx = x;
    while (cx < x + width) {
      final end = (cx + dashLen).clamp(cx, x + width);
      canvas.drawLine(Offset(cx, y), Offset(end, y), paint);
      cx += dashLen + gapLen;
    }
  }

  Color _resolveUnderlineColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;
    switch (colorType) {
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
