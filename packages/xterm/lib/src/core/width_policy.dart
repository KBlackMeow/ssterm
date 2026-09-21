import 'package:xterm/src/utils/unicode_v11.dart';

/// Selects the cell-width semantics of the terminal grid.
enum WidthProfile {
  /// Historical Unicode 11 East Asian width table only: no emoji-presentation
  /// double width, no Unicode 12–16 deltas, no variation-selector handling.
  /// Escape hatch for legacy full-screen apps laid out against old tables.
  legacy,

  /// EAW + Unicode 16 deltas + emoji-presentation double width + VS16/VS15
  /// presentation rules. Matches what iTerm2 and Terminal.app ship today.
  modern,
}

/// Host-configurable cell-width policy, iTerm2 parity.
///
/// The instance is mutable so a host app can flip [profile] or
/// [ambiguousDoubleWidth] on live terminals without recreating them; the
/// width of already-written cells is not recomputed retroactively (mirrors
/// iTerm2, which applies width changes to new output only).
class TerminalWidthPolicy {
  TerminalWidthPolicy({
    this.profile = WidthProfile.modern,
    this.ambiguousDoubleWidth = false,
  });

  WidthProfile profile;

  /// iTerm2's "Ambiguous Double Width" option: treat East_Asian_Width=A
  /// characters (±, ※, box-drawing variants, …) as two cells. Off by default,
  /// matching iTerm2's default and most TUI layout models.
  bool ambiguousDoubleWidth;

  /// Terminal cell width of [codePoint] under this policy.
  int widthOf(int codePoint) {
    switch (profile) {
      case WidthProfile.legacy:
        return unicodeV11.wcwidthLegacy(codePoint);
      case WidthProfile.modern:
        var width = unicodeV11.wcwidth(codePoint);
        if (width == 1 && ambiguousDoubleWidth && isAmbiguousWidth(codePoint)) {
          return 2;
        }
        return width;
    }
  }

  /// VS16/VS15 presentation rules are part of the modern profile only.
  bool get honorsVariationSelectors => profile == WidthProfile.modern;
}
