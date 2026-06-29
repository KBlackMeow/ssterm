import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';

abstract class MouseReporter {
  static String report(
    TerminalMouseButton button,
    TerminalMouseButtonState state,
    CellOffset position,
    MouseReportMode reportMode, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    bool motion = false,
  }) {
    // 1-based coordinates.
    final x = position.x + 1;
    final y = position.y + 1;

    // Modifier bits: shift=4, alt=8, ctrl=16, motion=32.
    int mods = 0;
    if (shift) mods |= 4;
    if (alt) mods |= 8;
    if (ctrl) mods |= 16;
    if (motion) mods |= 32;

    switch (reportMode) {
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        // Button ID 3 is used to signal a button release.
        final buttonID = state == TerminalMouseButtonState.up ? 3 : button.id;
        final btn = String.fromCharCode(32 + buttonID + mods);
        final col = (reportMode == MouseReportMode.normal && x > 223) ||
                (reportMode == MouseReportMode.utf && x > 2015)
            ? '\x00'
            : String.fromCharCode(32 + x);
        final row = (reportMode == MouseReportMode.normal && y > 223) ||
                (reportMode == MouseReportMode.utf && y > 2015)
            ? '\x00'
            : String.fromCharCode(32 + y);
        return "\x1b[M$btn$col$row";
      case MouseReportMode.sgr:
        final buttonID = button.id + mods;
        // Motion events always use 'M'; button release uses 'm'.
        final upDown =
            (motion || state == TerminalMouseButtonState.down) ? 'M' : 'm';
        return "\x1b[<$buttonID;$x;$y$upDown";
      case MouseReportMode.urxvt:
        final buttonID =
            32 + (state == TerminalMouseButtonState.up ? 3 : button.id) + mods;
        return "\x1b[$buttonID;$x;${y}M";
    }
  }
}
