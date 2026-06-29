abstract class CellFlags {
  static const bold = 1 << 0;
  static const faint = 1 << 1;
  static const italic = 1 << 2;
  static const underline = 1 << 3;
  static const blink = 1 << 4;
  static const inverse = 1 << 5;
  static const invisible = 1 << 6;
  static const strikethrough = 1 << 7;
  static const overline = 1 << 8;

  /// 3-bit underline style stored in bits 9-11.
  /// 0 = single (default), 1 = single, 2 = double, 3 = curly/wavy,
  /// 4 = dotted, 5 = dashed.
  static const underlineStyleMask = 0x7 << 9;
  static const underlineStyleShift = 9;
}
