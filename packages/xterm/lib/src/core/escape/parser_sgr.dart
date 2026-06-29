import 'package:xterm/src/core/color.dart';
import 'package:xterm/src/core/escape/handler.dart';

/// Dispatches SGR (Select Graphic Rendition) parameters to [handler].
///
/// Extracted from `EscapeParser._csiHandleSgr` so the logic can be
/// tested independently of the parser's internal state.
///
/// [paramSubs] is the parallel colon sub-parameter list produced by the
/// CSI parser.  `paramSubs?[i]` is non-null when `params[i]` had colon-
/// separated sub-params (e.g. `4:3` → params=[4], paramSubs=[[3]]).
void parseSgrParams(EscapeHandler handler, List<int> params,
    [List<List<int>?>? paramSubs]) {
  if (params.isEmpty) {
    return handler.resetCursorStyle();
  }

  // ignore: dead_code
  for (var i = 0; i < params.length; i++) {
    final param = params[i];
    final subs = paramSubs?[i];
    switch (param) {
      case 0:
        handler.resetCursorStyle();
        continue;
      case 1:
        handler.setCursorBold();
        continue;
      case 2:
        handler.setCursorFaint();
        continue;
      case 3:
        handler.setCursorItalic();
        continue;
      case 4:
        // SGR 4:x — underline with sub-type (colon format).
        if (subs != null && subs.isNotEmpty) {
          handler.setCursorUnderlineStyle(subs[0]);
        } else {
          handler.setCursorUnderline();
        }
        continue;
      case 5:
        handler.setCursorBlink();
        continue;
      case 7:
        handler.setCursorInverse();
        continue;
      case 8:
        handler.setCursorInvisible();
        continue;
      case 9:
        handler.setCursorStrikethrough();
        continue;

      case 21:
        handler.unsetCursorBold();
        continue;
      case 22:
        handler.unsetCursorFaint();
        continue;
      case 23:
        handler.unsetCursorItalic();
        continue;
      case 24:
        handler.unsetCursorUnderline();
        continue;
      case 25:
        handler.unsetCursorBlink();
        continue;
      case 27:
        handler.unsetCursorInverse();
        continue;
      case 28:
        handler.unsetCursorInvisible();
        continue;
      case 29:
        handler.unsetCursorStrikethrough();
        continue;

      case 30:
        handler.setForegroundColor16(NamedColor.black);
        continue;
      case 31:
        handler.setForegroundColor16(NamedColor.red);
        continue;
      case 32:
        handler.setForegroundColor16(NamedColor.green);
        continue;
      case 33:
        handler.setForegroundColor16(NamedColor.yellow);
        continue;
      case 34:
        handler.setForegroundColor16(NamedColor.blue);
        continue;
      case 35:
        handler.setForegroundColor16(NamedColor.magenta);
        continue;
      case 36:
        handler.setForegroundColor16(NamedColor.cyan);
        continue;
      case 37:
        handler.setForegroundColor16(NamedColor.white);
        continue;
      case 38:
        if (subs != null && subs.length >= 4 && subs[0] == 2) {
          // 38:2:r:g:b — colon sub-param format
          handler.setForegroundColorRgb(subs[1], subs[2], subs[3]);
        } else if (subs != null && subs.length >= 2 && subs[0] == 5) {
          // 38:5:n — colon sub-param format
          handler.setForegroundColor256(subs[1]);
        } else if (i + 4 < params.length && params[i + 1] == 2) {
          // 38;2;r;g;b — legacy semicolon format
          handler.setForegroundColorRgb(params[i + 2], params[i + 3], params[i + 4]);
          i += 4;
        } else if (i + 2 < params.length && params[i + 1] == 5) {
          // 38;5;n — legacy semicolon format
          handler.setForegroundColor256(params[i + 2]);
          i += 2;
        }
        continue;
      case 39:
        handler.resetForeground();
        continue;

      case 40:
        handler.setBackgroundColor16(NamedColor.black);
        continue;
      case 41:
        handler.setBackgroundColor16(NamedColor.red);
        continue;
      case 42:
        handler.setBackgroundColor16(NamedColor.green);
        continue;
      case 43:
        handler.setBackgroundColor16(NamedColor.yellow);
        continue;
      case 44:
        handler.setBackgroundColor16(NamedColor.blue);
        continue;
      case 45:
        handler.setBackgroundColor16(NamedColor.magenta);
        continue;
      case 46:
        handler.setBackgroundColor16(NamedColor.cyan);
        continue;
      case 47:
        handler.setBackgroundColor16(NamedColor.white);
        continue;
      case 48:
        if (subs != null && subs.length >= 4 && subs[0] == 2) {
          // 48:2:r:g:b
          handler.setBackgroundColorRgb(subs[1], subs[2], subs[3]);
        } else if (subs != null && subs.length >= 2 && subs[0] == 5) {
          // 48:5:n
          handler.setBackgroundColor256(subs[1]);
        } else if (i + 4 < params.length && params[i + 1] == 2) {
          handler.setBackgroundColorRgb(params[i + 2], params[i + 3], params[i + 4]);
          i += 4;
        } else if (i + 2 < params.length && params[i + 1] == 5) {
          handler.setBackgroundColor256(params[i + 2]);
          i += 2;
        }
        continue;
      case 49:
        handler.resetBackground();
        continue;

      case 53:
        handler.setCursorOverline();
        continue;
      case 55:
        handler.unsetCursorOverline();
        continue;

      case 58:
        // SGR 58: underline color
        if (subs != null && subs.length >= 4 && subs[0] == 2) {
          // 58:2:r:g:b
          handler.setUnderlineColorRgb(subs[1], subs[2], subs[3]);
        } else if (subs != null && subs.length >= 2 && subs[0] == 5) {
          // 58:5:n
          handler.setUnderlineColor256(subs[1]);
        } else if (i + 4 < params.length && params[i + 1] == 2) {
          handler.setUnderlineColorRgb(params[i + 2], params[i + 3], params[i + 4]);
          i += 4;
        } else if (i + 2 < params.length && params[i + 1] == 5) {
          handler.setUnderlineColor256(params[i + 2]);
          i += 2;
        }
        continue;
      case 59:
        handler.resetUnderlineColor();
        continue;

      case 90:
        handler.setForegroundColor16(NamedColor.brightBlack);
        continue;
      case 91:
        handler.setForegroundColor16(NamedColor.brightRed);
        continue;
      case 92:
        handler.setForegroundColor16(NamedColor.brightGreen);
        continue;
      case 93:
        handler.setForegroundColor16(NamedColor.brightYellow);
        continue;
      case 94:
        handler.setForegroundColor16(NamedColor.brightBlue);
        continue;
      case 95:
        handler.setForegroundColor16(NamedColor.brightMagenta);
        continue;
      case 96:
        handler.setForegroundColor16(NamedColor.brightCyan);
        continue;
      case 97:
        handler.setForegroundColor16(NamedColor.brightWhite);
        continue;

      case 100:
        handler.setBackgroundColor16(NamedColor.brightBlack);
        continue;
      case 101:
        handler.setBackgroundColor16(NamedColor.brightRed);
        continue;
      case 102:
        handler.setBackgroundColor16(NamedColor.brightGreen);
        continue;
      case 103:
        handler.setBackgroundColor16(NamedColor.brightYellow);
        continue;
      case 104:
        handler.setBackgroundColor16(NamedColor.brightBlue);
        continue;
      case 105:
        handler.setBackgroundColor16(NamedColor.brightMagenta);
        continue;
      case 106:
        handler.setBackgroundColor16(NamedColor.brightCyan);
        continue;
      case 107:
        handler.setBackgroundColor16(NamedColor.brightWhite);
        continue;

      default:
        handler.unsupportedStyle(param);
        continue;
    }
  }
}
