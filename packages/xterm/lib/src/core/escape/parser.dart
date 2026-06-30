import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/core/escape/parser_sgr.dart';
import 'package:xterm/src/utils/ascii.dart';
import 'package:xterm/src/utils/byte_consumer.dart';
import 'package:xterm/src/utils/char_code.dart';
import 'package:xterm/src/utils/lookup_table.dart';

/// [EscapeParser] translates control characters and escape sequences into
/// function calls that the terminal can handle.
///
/// Design goals:
///  * Zero object allocation during processing.
///  * No internal state. Same input will always produce same output.
class EscapeParser {
  final EscapeHandler handler;

  EscapeParser(this.handler);

  final _queue = ByteConsumer();

  /// Start of sequence or character being processed. Useful for debugging.
  var tokenBegin = 0;

  /// End of sequence or character being processed. Useful for debugging.
  int get tokenEnd => _queue.totalConsumed;

  void write(String chunk) {
    _queue.unrefConsumedBlocks();
    _queue.add(chunk);
    _process();
  }

  void _process() {
    while (_queue.isNotEmpty) {
      tokenBegin = _queue.totalConsumed;
      final char = _queue.consume();

      if (char == Ascii.ESC) {
        final processed = _processEscape();
        if (!processed) {
          _queue.rollback(tokenEnd - tokenBegin);
          return;
        }
      } else {
        _processChar(char);
      }
    }
  }

  void _processChar(int char) {
    if (char > _sbcHandlers.maxIndex) {
      handler.writeChar(char);
      return;
    }

    final sbcHandler = _sbcHandlers[char];
    if (sbcHandler == null) {
      handler.unkownEscape(char);
      return;
    }

    sbcHandler();
  }

  /// Processes a sequence of characters that starts with an escape character.
  /// Returns [true] if the sequence was processed, [false] if it was not.
  bool _processEscape() {
    if (_queue.isEmpty) return false;

    final escapeChar = _queue.consume();
    final escapeHandler = _escHandlers[escapeChar];

    if (escapeHandler == null) {
      handler.unkownEscape(escapeChar);
      return true;
    }

    return escapeHandler();
  }

  late final _sbcHandlers = FastLookupTable<_SbcHandler>({
    0x07: handler.bell,
    0x08: handler.backspaceReturn,
    0x09: handler.tab,
    0x0a: handler.lineFeed,
    0x0b: handler.lineFeed,
    0x0c: handler.lineFeed,
    0x0d: handler.carriageReturn,
    0x0e: handler.shiftOut,
    0x0f: handler.shiftIn,
  });

  late final _escHandlers = FastLookupTable<_EscHandler>({
    '['.charCode: _escHandleCSI,
    ']'.charCode: _escHandleOSC,
    '7'.charCode: _escHandleSaveCursor,
    '8'.charCode: _escHandleRestoreCursor,
    'D'.charCode: _escHandleIndex,
    'E'.charCode: _escHandleNextLine,
    'H'.charCode: _escHandleTabSet,
    'M'.charCode: _escHandleReverseIndex,
    // 'P'.charCode: _unsupportedHandler, // Sixel
    // 'c'.charCode: _unsupportedHandler,
    // '#'.charCode: _unsupportedHandler,
    '('.charCode: _escHandleDesignateCharset0, //  SCS - G0
    ')'.charCode: _escHandleDesignateCharset1, //  SCS - G1
    // '*'.charCode: _voidHandler(1), // TODO: G2 (vt220)
    // '+'.charCode: _voidHandler(1), // TODO: G3 (vt220)
    '>'.charCode: _escHandleResetAppKeypadMode, // TODO: Normal Keypad
    '='.charCode: _escHandleSetAppKeypadMode, // TODO: Application Keypad
  });

  /// `ESC 7` Save Cursor (DECSC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a7/
  bool _escHandleSaveCursor() {
    handler.saveCursor();
    return true;
  }

  /// `ESC 8` Restore Cursor (DECRC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a8/
  bool _escHandleRestoreCursor() {
    handler.restoreCursor();
    return true;
  }

  /// `ESC D` Index (IND)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cd/
  bool _escHandleIndex() {
    handler.index();
    return true;
  }

  /// `ESC E` Next Line (NEL)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ce/
  bool _escHandleNextLine() {
    handler.nextLine();
    return true;
  }

  /// `ESC H` Horizontal Tab Set (HTS)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ch/
  bool _escHandleTabSet() {
    handler.setTapStop();
    return true;
  }

  /// `ESC M` Reverse Index (RI)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  bool _escHandleReverseIndex() {
    handler.reverseIndex();
    return true;
  }

  bool _escHandleDesignateCharset0() {
    if (_queue.isEmpty) return false;
    int name = _queue.consume();
    handler.designateCharset(0, name);
    return true;
  }

  bool _escHandleDesignateCharset1() {
    if (_queue.isEmpty) return false;
    int name = _queue.consume();
    handler.designateCharset(1, name);
    return true;
  }

  /// `ESC >` Reset Application Keypad Mode (DECKPNM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3c_greater_than/
  bool _escHandleSetAppKeypadMode() {
    handler.setAppKeypadMode(true);
    return true;
  }

  /// `ESC =` Set Application Keypad Mode (DECKPAM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3d_equals/
  bool _escHandleResetAppKeypadMode() {
    handler.setAppKeypadMode(false);
    return true;
  }

  bool _escHandleCSI() {
    final consumed = _consumeCsi();
    if (!consumed) return false;

    final csiHandler = _csiHandlers[_csi.finalByte];

    if (csiHandler == null) {
      handler.unknownCSI(_csi.finalByte);
    } else {
      csiHandler();
    }

    return true;
  }

  /// The last parsed [_Csi]. This is a mutable singleton by design to reduce
  /// object allocations.
  final _csi = _Csi(finalByte: 0, params: [], paramSubs: []);

  /// Reusable buffer for colon sub-parameters to avoid allocation per sequence.
  final _tempSubParams = <int>[];

  /// Parse a CSI from the head of the queue. Return false if the CSI isn't
  /// complete. After a CSI is successfully parsed, [_csi] is updated.
  ///
  /// Colon-separated sub-parameters (e.g. `38:2:r:g:b`, `4:3`) are preserved
  /// in [_Csi.paramSubs] so handlers can distinguish `4:3` (wavy underline)
  /// from `4;3` (underline + italic).
  bool _consumeCsi() {
    if (_queue.isEmpty) {
      return false;
    }

    _csi.params.clear();
    _csi.paramSubs.clear();
    _csi.intermediate = null;

    // test whether the csi is a `CSI ? Ps ...` or `CSI Ps ...`
    final prefix = _queue.peek();
    if (prefix >= Ascii.colon && prefix <= Ascii.questionMark) {
      _csi.prefix = prefix;
      _queue.consume();
    } else {
      _csi.prefix = null;
    }

    var param = 0;
    var hasParam = false;
    var inSubParam = false;
    var primaryParam = 0;

    while (true) {
      // The sequence isn't completed, just ignore it.
      if (_queue.isEmpty) {
        return false;
      }

      final char = _queue.consume();

      if (char == Ascii.colon) {
        if (!inSubParam) {
          // First colon: current accumulated value is the primary param.
          primaryParam = hasParam ? param : 0;
          inSubParam = true;
          _tempSubParams.clear();
        } else {
          // Subsequent colon: flush current value into sub-params.
          _tempSubParams.add(hasParam ? param : 0);
        }
        param = 0;
        hasParam = false;
        continue;
      }

      if (char == Ascii.semicolon) {
        _flushCsiParam(inSubParam, primaryParam, hasParam, param);
        param = 0;
        hasParam = false;
        inSubParam = false;
        primaryParam = 0;
        continue;
      }

      if (char >= Ascii.num0 && char <= Ascii.num9) {
        hasParam = true;
        param = param * 10 + (char - Ascii.num0);
        continue;
      }

      if (char > Ascii.NULL && char < Ascii.num0) {
        // Intermediate byte (e.g. SP = 0x20 before 'q' in DECSCUSR).
        _csi.intermediate = char;
        continue;
      }

      if (char >= Ascii.atSign && char <= Ascii.tilde) {
        _flushCsiParam(inSubParam, primaryParam, hasParam, param);
        _csi.finalByte = char;
        return true;
      }
    }
  }

  void _flushCsiParam(
      bool inSubParam, int primaryParam, bool hasParam, int param) {
    if (inSubParam) {
      _tempSubParams.add(hasParam ? param : 0);
      _csi.params.add(primaryParam);
      _csi.paramSubs.add(List.of(_tempSubParams));
      _tempSubParams.clear();
    } else if (hasParam) {
      _csi.params.add(param);
      _csi.paramSubs.add(null);
    }
  }

  late final _csiHandlers = FastLookupTable<_CsiHandler>({
    // 'a'.codeUnitAt(0): _csiHandleCursorHorizontalRelative,
    'b'.codeUnitAt(0): _csiHandleRepeatPreviousCharacter,
    'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes,
    'd'.codeUnitAt(0): _csiHandleLinePositionAbsolute,
    'f'.codeUnitAt(0): _csiHandleCursorPosition,
    'g'.codeUnitAt(0): _csiHandelClearTabStop,
    'h'.codeUnitAt(0): _csiHandleMode,
    'l'.codeUnitAt(0): _csiHandleMode,
    'm'.codeUnitAt(0): _csiHandleSgr,
    'n'.codeUnitAt(0): _csiHandleDeviceStatusReport,
    'q'.codeUnitAt(0): _csiHandleDecscusr,
    'r'.codeUnitAt(0): _csiHandleSetMargins,
    't'.codeUnitAt(0): _csiWindowManipulation,
    'A'.codeUnitAt(0): _csiHandleCursorUp,
    'B'.codeUnitAt(0): _csiHandleCursorDown,
    'C'.codeUnitAt(0): _csiHandleCursorForward,
    'D'.codeUnitAt(0): _csiHandleCursorBackward,
    'E'.codeUnitAt(0): _csiHandleCursorNextLine,
    'F'.codeUnitAt(0): _csiHandleCursorPrecedingLine,
    'G'.codeUnitAt(0): _csiHandleCursorHorizontalAbsolute,
    'H'.codeUnitAt(0): _csiHandleCursorPosition,
    'J'.codeUnitAt(0): _csiHandleEraseDisplay,
    'K'.codeUnitAt(0): _csiHandleEraseLine,
    'L'.codeUnitAt(0): _csiHandleInsertLines,
    'M'.codeUnitAt(0): _csiHandleDeleteLines,
    'P'.codeUnitAt(0): _csiHandleDelete,
    'S'.codeUnitAt(0): _csiHandleScrollUp,
    'T'.codeUnitAt(0): _csiHandleScrollDown,
    'X'.codeUnitAt(0): _csiHandleEraseCharacters,
    '@'.codeUnitAt(0): _csiHandleInsertBlankCharacters,
  });

  /// `ESC [ Ps a` Cursor Horizontal Position Relative (HPR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sa/
  // void _csiHandleCursorHorizontalRelative() {
  //   if (_csi.params.isEmpty) {
  //     handler.cursorHorizontal(1);
  //   } else {
  //     handler.cursorHorizontal(_csi.params[0]);
  //   }
  // }

  /// `ESC [ Ps b` Repeat Previous Character (REP)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sb/
  void _csiHandleRepeatPreviousCharacter() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.repeatPreviousCharacter(amount);
  }

  /// `ESC [ Ps c` Device Attributes (DA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sc/
  void _csiHandleSendDeviceAttributes() {
    switch (_csi.prefix) {
      case Ascii.greaterThan:
        return handler.sendSecondaryDeviceAttributes();
      case Ascii.equal:
        return handler.sendTertiaryDeviceAttributes();
      default:
        handler.sendPrimaryDeviceAttributes();
    }
  }

  /// `ESC [ Ps d` Cursor Vertical Position Absolute (VPA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sd/
  void _csiHandleLinePositionAbsolute() {
    var y = 1;

    if (_csi.params.isNotEmpty) {
      y = _csi.params[0];
    }

    handler.setCursorY(y - 1);
  }

  /// `ESC [ Ps ; Ps f` Alias: Set Cursor Position
  ///
  /// https://terminalguide.namepad.de/seq/csi_sf/
  void _csiHandleCursorPosition() {
    var row = 1;
    var col = 1;

    if (_csi.params.length == 2) {
      row = _csi.params[0];
      col = _csi.params[1];
    }

    handler.setCursor(col - 1, row - 1);
  }

  /// `ESC [ Ps g` Tab Clear (TBC)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sg/
  void _csiHandelClearTabStop() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.clearTabStopUnderCursor();
      default:
        return handler.clearAllTabStops();
    }
  }

  /// - `ESC [ [ Pm ] h Set Mode (SM)` https://terminalguide.namepad.de/seq/csi_sm/
  /// - `ESC [ ? [ Pm ] h` Set Mode (?) (SM) https://terminalguide.namepad.de/seq/csi_sh__p/
  /// - `ESC [ [ Pm ] l` Reset Mode (RM) https://terminalguide.namepad.de/seq/csi_rm/
  /// - `ESC [ ? [ Pm ] l` Reset Mode (?) (RM) https://terminalguide.namepad.de/seq/csi_sl__p/
  void _csiHandleMode() {
    final isEnabled = _csi.finalByte == Ascii.h;

    final isDecModes = _csi.prefix == Ascii.questionMark;

    if (isDecModes) {
      for (var mode in _csi.params) {
        _setDecMode(mode, isEnabled);
      }
    } else {
      for (var mode in _csi.params) {
        _setMode(mode, isEnabled);
      }
    }
  }

  /// `ESC [ [ Ps ] m` Select Graphic Rendition (SGR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sm/
  void _csiHandleSgr() {
    // SGR is `CSI Pm m`. Forms with a real private-marker prefix `< = > ?`
    // (0x3C–0x3F) such as `CSI > Ps m` (XTMODKEYS / modifyOtherKeys, emitted by
    // Claude Code and ConPTY) share the `m` final byte but are NOT SGR. Treating
    // them as SGR mis-sets attributes — e.g. `\x1b[>4m` was parsed as `SGR 4`
    // (underline on) and leaked underline into the shell prompt and everything
    // after it. Note the parser also captures a leading `:`/`;` (0x3A/0x3B) as a
    // "prefix" — those are (malformed) empty parameters, NOT private markers, so
    // they must still be handled as SGR.
    final prefix = _csi.prefix;
    if (prefix != null &&
        prefix >= Ascii.lessThan &&
        prefix <= Ascii.questionMark) {
      return;
    }
    parseSgrParams(handler, _csi.params, _csi.paramSubs);
  }

  /// `ESC [ Ps n` Device Status Report [Dispatch] (DSR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sn/
  void _csiHandleDeviceStatusReport() {
    if (_csi.params.isEmpty) return;

    switch (_csi.params[0]) {
      case 5:
        return handler.sendOperatingStatus();
      case 6:
        return handler.sendCursorPosition();
    }
  }

  /// `ESC [ Ps SP q` Set Cursor Style (DECSCUSR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sp_sq/
  void _csiHandleDecscusr() {
    // Intermediate byte must be SP (0x20); bare `q` without SP is ignored.
    if (_csi.intermediate != Ascii.space) return;

    final ps = _csi.params.isEmpty ? 0 : _csi.params[0];
    handler.setCursorShape(ps);
  }

  /// `ESC [ Ps ; Ps r` Set Top and Bottom Margins (DECSTBM)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sr/
  void _csiHandleSetMargins() {
    var top = 1;
    int? bottom;

    if (_csi.params.length > 2) return;

    if (_csi.params.isNotEmpty) {
      top = _csi.params[0];

      if (_csi.params.length == 2) {
        bottom = _csi.params[1] - 1;
      }
    }

    handler.setMargins(top - 1, bottom);
  }

  /// `ESC [ Ps t` Window operations [DISPATCH]
  ///
  /// https://terminalguide.namepad.de/seq/csi_st/
  void _csiWindowManipulation() {
    // The sequence needs at least one parameter.
    if (_csi.params.isEmpty) {
      return;
    }
    // Most the commands in this group are either of the scope of this package,
    // or should be disabled for security risks.
    switch (_csi.params.first) {
      // Window handling is currently not in the scope of the package.
      case 1: // Restore Terminal Window (show window if minimized)
      case 2: // Minimize Terminal Window
      case 3: // Set Terminal Window Position
      case 4: // Set Terminal Window Size in Pixels
      case 5: // Raise Terminal Window
      case 6: // Lower Terminal Window
      case 7: // Refresh/Redraw Terminal Window
        return;
      case 8: // Set Terminal Window Size (in characters)
        // This CSI contains 2 more parameters: width and height.
        if (_csi.params.length != 3) {
          return;
        }
        final rows = _csi.params[1];
        final cols = _csi.params[2];
        handler.resize(cols, rows);
        return;
      // Window handling is currently no in the scope of the package.
      case 9: // Maximize Terminal Window
      case 10: // Alias: Maximize Terminal Window
      case 11: // Report Terminal Window State
      case 13: // Report Terminal Window Position
      case 14: // Report Terminal Window Size in Pixels
      case 15: // Report Screen Size in Pixels
      case 16: // Report Cell Size in Pixels
        return;
      case 18: // Report Terminal Size (in characters)
        handler.sendSize();
        return;
      // Screen handling is currently no in the scope of the package.
      case 19: // Report Screen Size (in characters)
      // Disabled as these can a security risk.
      case 20: // Get Icon Title
      case 21: // Get Terminal Title
      // Not implemented.
      case 22: // Push Terminal Title
      case 23: // Pop Terminal Title
        return;
      // Unknown CSI.
      default:
        return;
    }
  }

  /// `ESC [ Ps A` Cursor Up (CUU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ca/
  void _csiHandleCursorUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(-amount);
  }

  /// `ESC [ Ps B` Cursor Down (CUD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cb/
  void _csiHandleCursorDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(amount);
  }

  /// `ESC [ Ps C` Cursor Right (CUF)
  ///
  /// Cursor Right (CUF)
  void _csiHandleCursorForward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(amount);
  }

  /// `ESC [ Ps D` Cursor Left (CUB)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cd/
  void _csiHandleCursorBackward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(-amount);
  }

  /// `ESC [ Ps E` Cursor Next Line (CNL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ce/
  void _csiHandleCursorNextLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorNextLine(amount);
  }

  /// `ESC [ Ps F` Cursor Previous Line (CPL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cf/
  void _csiHandleCursorPrecedingLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorPrecedingLine(amount);
  }

  void _csiHandleCursorHorizontalAbsolute() {
    var x = 1;

    if (_csi.params.isNotEmpty) {
      x = _csi.params[0];
      if (x == 0) x = 1;
    }

    handler.setCursorX(x - 1);
  }

  /// ESC [ Ps J Erase Display [Dispatch] (ED)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cj/
  void _csiHandleEraseDisplay() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseDisplayBelow();
      case 1:
        return handler.eraseDisplayAbove();
      case 2:
        return handler.eraseDisplay();
      case 3:
        return handler.eraseScrollbackOnly();
    }
  }

  /// `ESC [ Ps K` Erase Line [Dispatch] (EL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ck/
  void _csiHandleEraseLine() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseLineRight();
      case 1:
        return handler.eraseLineLeft();
      case 2:
        return handler.eraseLine();
    }
  }

  /// `ESC [ Ps L` Insert Line (IL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cl/
  void _csiHandleInsertLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertLines(amount);
  }

  /// ESC [ Ps M Delete Line (DL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cm/
  void _csiHandleDeleteLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteLines(amount);
  }

  /// ESC [ Ps P Delete Character (DCH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cp/
  void _csiHandleDelete() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteChars(amount);
  }

  /// `ESC [ Ps S` Scroll Up (SU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cs/
  void _csiHandleScrollUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollUp(amount);
  }

  /// `ESC [ Ps T `Scroll Down (SD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ct_1param/
  void _csiHandleScrollDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollDown(amount);
  }

  /// `ESC [ Ps X` Erase Character (ECH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cx/
  void _csiHandleEraseCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.eraseChars(amount);
  }

  /// `ESC [ Ps @` Insert Blanks (ICH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_x40_at/
  ///
  /// Inserts amount spaces at current cursor position moving existing cell
  /// contents to the right. The contents of the amount right-most columns in
  /// the scroll region are lost. The cursor position is not changed.
  void _csiHandleInsertBlankCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertBlankChars(amount);
  }

  void _setMode(int mode, bool enabled) {
    switch (mode) {
      case 4:
        return handler.setInsertMode(enabled);
      case 20:
        return handler.setLineFeedMode(enabled);
      default:
        return handler.setUnknownMode(mode, enabled);
    }
  }

  void _setDecMode(int mode, bool enabled) {
    switch (mode) {
      case 1:
        return handler.setCursorKeysMode(enabled);
      case 3:
        return handler.setColumnMode(enabled);
      case 5:
        return handler.setReverseDisplayMode(enabled);
      case 6:
        return handler.setOriginMode(enabled);
      case 7:
        return handler.setAutoWrapMode(enabled);
      case 9:
        return enabled
            ? handler.setMouseMode(MouseMode.clickOnly)
            : handler.setMouseMode(MouseMode.none);
      case 12:
      case 13:
        return handler.setCursorBlinkMode(enabled);
      case 25:
        return handler.setCursorVisibleMode(enabled);
      case 47:
        if (enabled) {
          handler.saveCursor();
          handler.useAltBuffer();
          // Reset text attrs and input modes so leaked shell state (e.g.
          // underline from PS1, application cursor mode from readline) does
          // not affect what the full-screen app writes or reads.
          handler.resetSavedCursor();
          handler.resetCursorStyle();
          handler.setCursorKeysMode(false);
          handler.setAppKeypadMode(false);
        } else {
          handler.useMainBuffer();
          handler.restoreCursor();
        }
        return;
      case 66:
        return handler.setAppKeypadMode(enabled);
      case 1000:
      case 10061000:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1001:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1002:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollDrag)
            : handler.setMouseMode(MouseMode.none);
      case 1003:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollMove)
            : handler.setMouseMode(MouseMode.none);
      case 1004:
        return handler.setReportFocusMode(enabled);
      case 1005:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.utf)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1006:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.sgr)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1007:
        return handler.setAltBufferMouseScrollMode(enabled);
      case 1015:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.urxvt)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1047:
        if (enabled) {
          handler.useAltBuffer();
          // Reset text attrs and input modes so leaked shell state does not
          // affect what the full-screen app writes or reads.
          handler.resetSavedCursor();
          handler.resetCursorStyle();
          handler.setCursorKeysMode(false);
          handler.setAppKeypadMode(false);
        } else {
          handler.clearAltBuffer();
          handler.useMainBuffer();
        }
        return;
      case 1048:
        if (enabled) {
          return handler.saveCursor();
        } else {
          return handler.restoreCursor();
        }
      case 1049:
        if (enabled) {
          handler.saveCursor();
          handler.clearAltBuffer();
          handler.useAltBuffer();
          // clearAltBuffer() already resetSavedCursor(); reset SGR / input modes
          // so leaked shell state does not affect the full-screen app.
          handler.resetCursorStyle();
          handler.setCursorKeysMode(false);
          handler.setAppKeypadMode(false);
        } else {
          handler.useMainBuffer();
          handler.restoreCursor();
          // On Windows, ConPTY may truncate the app's post-exit \x1b[m, leaving
          // SGR attributes (underline, color) from the saved cursor state active
          // in the main buffer. Reset style unconditionally so Ctrl+C and clean
          // exits both leave a clean main buffer.
          handler.resetCursorStyle();
        }
        return;
      case 2004:
        return handler.setBracketedPasteMode(enabled);
      default:
        return handler.setUnknownDecMode(mode, enabled);
    }
  }

  /// Parse a OSC sequence from the queue. Returns true if a sequence was
  /// found and handled.
  bool _escHandleOSC() {
    final consumed = _consumeOsc();
    if (!consumed) {
      return false;
    }

    if (_osc.isEmpty) {
      return true;
    }

    // Common OSCs
    if (_osc.length >= 2) {
      final ps = _osc[0];
      final pt = _osc[1];

      switch (ps) {
        case '0':
          handler.setTitle(pt);
          handler.setIconName(pt);
          return true;
        case '1':
          handler.setIconName(pt);
          return true;
        case '2':
          handler.setTitle(pt);
          return true;
        case '7':
          // OSC 7: current working directory URI (file:///path)
          handler.setWorkingDirectory(pt);
          return true;
        case '52':
          // OSC 52: clipboard access
          // _osc[1] = selection target (usually "c"), _osc[2] = base64 data or "?"
          final data = _osc.length >= 3 ? _osc[2] : pt;
          if (data == '?') {
            handler.requestClipboard();
          } else {
            handler.setClipboard(data);
          }
          return true;
      }
    }

    // Private extensions
    handler.unknownOSC(_osc[0], _osc.sublist(1));

    return true;
  }

  final _osc = <String>[];

  bool _consumeOsc() {
    _osc.clear();
    final param = StringBuffer();

    while (true) {
      if (_queue.isEmpty) {
        return false;
      }

      final char = _queue.consume();

      // OSC terminates with BEL
      if (char == Ascii.BEL) {
        _osc.add(param.toString());
        return true;
      }

      /// OSC terminates with ST
      if (char == Ascii.ESC) {
        if (_queue.isEmpty) {
          return false;
        }

        if (_queue.consume() == Ascii.backslash) {
          _osc.add(param.toString());
        }

        return true;
      }

      /// Parse next parameter
      if (char == Ascii.semicolon) {
        _osc.add(param.toString());
        param.clear();
        continue;
      }

      param.writeCharCode(char);
    }
  }
}

class _Csi {
  _Csi({
    required this.params,
    required this.paramSubs,
    required this.finalByte,
  });

  int? prefix;

  List<int> params;

  /// Colon sub-parameters for each entry in [params]. `paramSubs[i]` is null
  /// when no colon was used for `params[i]`, or a non-empty list of the colon-
  /// separated values that followed the primary param value.
  List<List<int>?> paramSubs;

  /// Last intermediate byte seen before the final byte (e.g. SP = 0x20 in
  /// DECSCUSR `CSI Ps SP q`). Null if no intermediate byte was present.
  int? intermediate;

  int finalByte;

  @override
  String toString() {
    return params.join(';') + String.fromCharCode(finalByte);
  }
}

/// Function that handles a sequence of characters that starts with an escape.
/// Returns [true] if the sequence was processed, [false] if it was not.
typedef _EscHandler = bool Function();

typedef _SbcHandler = void Function();

typedef _CsiHandler = void Function();
