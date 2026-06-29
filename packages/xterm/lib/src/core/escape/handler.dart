import 'package:xterm/src/core/mouse/mode.dart';

abstract class EscapeHandler {
  void writeChar(int char);

  /* SBC */

  void bell();

  void backspaceReturn();

  void tab();

  void lineFeed();

  void carriageReturn();

  void shiftOut();

  void shiftIn();

  void unknownSBC(int char);

  /* ANSI sequence */

  void saveCursor();

  void restoreCursor();

  /// Clears the DECSC save slot on the active buffer.
  void resetSavedCursor();

  void index();

  void nextLine();

  void setTapStop();

  void reverseIndex();

  void designateCharset(int charset, int name);

  void unkownEscape(int char);

  /* CSI */

  void repeatPreviousCharacter(int n);

  void setCursor(int x, int y);

  void setCursorX(int x);

  void setCursorY(int y);

  void sendPrimaryDeviceAttributes();

  void clearTabStopUnderCursor();

  void clearAllTabStops();

  void moveCursorX(int offset);

  void moveCursorY(int n);

  void sendSecondaryDeviceAttributes();

  void sendTertiaryDeviceAttributes();

  void sendOperatingStatus();

  void sendCursorPosition();

  void setMargins(int i, [int? bottom]);

  void cursorNextLine(int amount);

  void cursorPrecedingLine(int amount);

  void eraseDisplayBelow();

  void eraseDisplayAbove();

  void eraseDisplay();

  void eraseScrollbackOnly();

  void eraseLineRight();

  void eraseLineLeft();

  void eraseLine();

  void insertLines(int amount);

  void deleteLines(int amount);

  void deleteChars(int amount);

  void scrollUp(int amount);

  void scrollDown(int amount);

  void eraseChars(int amount);

  void insertBlankChars(int amount);

  void unknownCSI(int finalByte);

  /// DECSCUSR — Set Cursor Style (CSI Ps SP q).
  ///
  /// [ps] is the raw parameter: 0/1 = blink block, 2 = steady block,
  /// 3 = blink underline, 4 = steady underline, 5 = blink bar, 6 = steady bar.
  void setCursorShape(int ps);

  /* Modes */

  void setInsertMode(bool enabled);

  void setLineFeedMode(bool enabled);

  void setUnknownMode(int mode, bool enabled);

  /* DEC Private modes */

  void setCursorKeysMode(bool enabled);

  void setReverseDisplayMode(bool enabled);

  void setOriginMode(bool enabled);

  void setColumnMode(bool enabled);

  void setAutoWrapMode(bool enabled);

  void setMouseMode(MouseMode mode);

  void setCursorBlinkMode(bool enabled);

  void setCursorVisibleMode(bool enabled);

  void useAltBuffer();

  void useMainBuffer();

  void clearAltBuffer();

  void setAppKeypadMode(bool enabled);

  void setReportFocusMode(bool enabled);

  void setMouseReportMode(MouseReportMode mode);

  void setAltBufferMouseScrollMode(bool enabled);

  void setBracketedPasteMode(bool enabled);

  void setUnknownDecMode(int mode, bool enabled);

  void resize(int cols, int rows);

  void sendSize();

  /* Select Graphic Rendition (SGR) */

  void resetCursorStyle();

  void setCursorBold();

  void setCursorFaint();

  void setCursorItalic();

  void setCursorUnderline();

  /// Sets the underline style sub-type.
  ///
  /// [style]: 0 = default/off, 1 = single, 2 = double, 3 = curly/wavy,
  ///          4 = dotted, 5 = dashed.
  void setCursorUnderlineStyle(int style);

  void setCursorBlink();

  void setCursorInverse();

  void setCursorInvisible();

  void setCursorStrikethrough();

  void setCursorOverline();

  void unsetCursorBold();

  void unsetCursorFaint();

  void unsetCursorItalic();

  void unsetCursorUnderline();

  void unsetCursorBlink();

  void unsetCursorInverse();

  void unsetCursorInvisible();

  void unsetCursorStrikethrough();

  void unsetCursorOverline();

  void setForegroundColor16(int color);

  void setForegroundColor256(int index);

  void setForegroundColorRgb(int r, int g, int b);

  void resetForeground();

  void setBackgroundColor16(int color);

  void setBackgroundColor256(int index);

  void setBackgroundColorRgb(int r, int g, int b);

  void resetBackground();

  /// SGR 58: set underline color (256-color palette index).
  void setUnderlineColor256(int index);

  /// SGR 58: set underline color (24-bit RGB).
  void setUnderlineColorRgb(int r, int g, int b);

  /// SGR 59: reset underline color to default.
  void resetUnderlineColor();

  void unsupportedStyle(int param);

  /* OSC */

  void setTitle(String name);

  void setIconName(String name);

  /// OSC 7: current working directory URI reported by the shell.
  void setWorkingDirectory(String uri);

  /// OSC 52 write: write [data] (base64-encoded) to the system clipboard.
  void setClipboard(String data);

  /// OSC 52 read: terminal should respond with current clipboard contents.
  void requestClipboard();

  void unknownOSC(String code, List<String> args);
}
