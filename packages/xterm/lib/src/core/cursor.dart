import 'package:xterm/src/core/cell.dart';

class CursorStyle {
  int foreground;

  int background;

  int attrs;

  /// Encoded underline color (same CellColor encoding as [foreground]).
  /// Zero means "use foreground color" (default).
  int underlineColor;

  CursorStyle({
    this.foreground = 0,
    this.background = 0,
    this.attrs = 0,
    this.underlineColor = 0,
  });

  static final empty = CursorStyle();

  void setBold() {
    attrs |= CellAttr.bold;
  }

  void setFaint() {
    attrs |= CellAttr.faint;
  }

  void setItalic() {
    attrs |= CellAttr.italic;
  }

  void setUnderline() {
    attrs |= CellAttr.underline;
    // Clear style sub-type; plain SGR 4 means single underline.
    attrs = (attrs & ~CellAttr.underlineStyleMask) |
        (1 << CellAttr.underlineStyleShift);
  }

  /// Set underline with explicit style sub-type.
  ///
  /// [style]: 0 = off, 1 = single, 2 = double, 3 = curly/wavy,
  ///          4 = dotted, 5 = dashed.
  void setUnderlineStyle(int style) {
    if (style == 0) {
      attrs &= ~(CellAttr.underline | CellAttr.underlineStyleMask);
    } else {
      attrs |= CellAttr.underline;
      attrs = (attrs & ~CellAttr.underlineStyleMask) |
          ((style & 0x7) << CellAttr.underlineStyleShift);
    }
  }

  void setBlink() {
    attrs |= CellAttr.blink;
  }

  void setInverse() {
    attrs |= CellAttr.inverse;
  }

  void setInvisible() {
    attrs |= CellAttr.invisible;
  }

  void setStrikethrough() {
    attrs |= CellAttr.strikethrough;
  }

  void setOverline() {
    attrs |= CellAttr.overline;
  }

  void unsetBold() {
    attrs &= ~CellAttr.bold;
  }

  void unsetFaint() {
    attrs &= ~CellAttr.faint;
  }

  void unsetItalic() {
    attrs &= ~CellAttr.italic;
  }

  void unsetUnderline() {
    attrs &= ~(CellAttr.underline | CellAttr.underlineStyleMask);
  }

  void unsetBlink() {
    attrs &= ~CellAttr.blink;
  }

  void unsetInverse() {
    attrs &= ~CellAttr.inverse;
  }

  void unsetInvisible() {
    attrs &= ~CellAttr.invisible;
  }

  void unsetStrikethrough() {
    attrs &= ~CellAttr.strikethrough;
  }

  void unsetOverline() {
    attrs &= ~CellAttr.overline;
  }

  bool get isBold => (attrs & CellAttr.bold) != 0;

  bool get isFaint => (attrs & CellAttr.faint) != 0;

  bool get isItalis => (attrs & CellAttr.italic) != 0;

  bool get isUnderline => (attrs & CellAttr.underline) != 0;

  int get underlineStyle =>
      (attrs & CellAttr.underlineStyleMask) >> CellAttr.underlineStyleShift;

  bool get isBlink => (attrs & CellAttr.blink) != 0;

  bool get isInverse => (attrs & CellAttr.inverse) != 0;

  bool get isInvisible => (attrs & CellAttr.invisible) != 0;

  bool get isOverline => (attrs & CellAttr.overline) != 0;

  void setForegroundColor16(int color) {
    foreground = color | CellColor.named;
  }

  void setForegroundColor256(int color) {
    foreground = color | CellColor.palette;
  }

  void setForegroundColorRgb(int r, int g, int b) {
    foreground = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetForegroundColor() {
    foreground = 0; // | CellColor.normal;
  }

  void setBackgroundColor16(int color) {
    background = color | CellColor.named;
  }

  void setBackgroundColor256(int color) {
    background = color | CellColor.palette;
  }

  void setBackgroundColorRgb(int r, int g, int b) {
    background = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetBackgroundColor() {
    background = 0; // | CellColor.normal;
  }

  void setUnderlineColor256(int color) {
    underlineColor = color | CellColor.palette;
  }

  void setUnderlineColorRgb(int r, int g, int b) {
    underlineColor = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetUnderlineColor() {
    underlineColor = 0;
  }

  void reset() {
    foreground = 0;
    background = 0;
    attrs = 0;
    underlineColor = 0;
  }
}

class CursorPosition {
  int x;

  int y;

  CursorPosition(this.x, this.y);
}
