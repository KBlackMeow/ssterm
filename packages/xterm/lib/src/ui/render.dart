import 'dart:async';
import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';

typedef EditableRectCallback = void Function(Rect rect, Rect caretRect);

class RenderTerminal extends RenderBox with RelayoutWhenSystemFontsChangeMixin {
  RenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool autoResize,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    required bool alwaysShowCursor,
    required bool cursorBlink,
    required int cursorBlinkPeriodMs,
    EditableRectCallback? onEditableRect,
    String? composingText,
  })  : _terminal = terminal,
        _controller = controller,
        _offset = offset,
        _padding = padding,
        _autoResize = autoResize,
        _focusNode = focusNode,
        _cursorType = cursorType,
        _alwaysShowCursor = alwaysShowCursor,
        _cursorBlink = cursorBlink,
        _cursorBlinkPeriodMs = cursorBlinkPeriodMs,
        _onEditableRect = onEditableRect,
        _composingText = composingText,
        _painter = TerminalPainter(
          theme: theme,
          textStyle: textStyle,
          textScaler: textScaler,
        );

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _resizeTerminalIfNeeded();
    markNeedsLayout();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    markNeedsPaint();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    markNeedsPaint();
  }

  bool _cursorBlink;
  set cursorBlink(bool value) {
    if (value == _cursorBlink) return;
    _cursorBlink = value;
    if (attached) {
      _restartBlinkTimer();
    } else {
      _cursorBlinkPhase = true;
    }
    markNeedsPaint();
  }

  int _cursorBlinkPeriodMs;
  set cursorBlinkPeriodMs(int value) {
    if (value == _cursorBlinkPeriodMs) return;
    _cursorBlinkPeriodMs = value;
    if (attached && _cursorBlink) {
      _restartBlinkTimer();
    }
  }

  bool _cursorBlinkPhase = true;
  Timer? _blinkTimer;

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    markNeedsLayout();
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    markNeedsPaint();
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  var _stickToBottom = true;
  bool _editableRectUpdateScheduled = false;
  bool _wasUsingAltBuffer = false;

  void _onScroll() {
    final lineHeight = _painter.cellSize.height;
    _stickToBottom = (_maxScrollExtent - _offset.pixels).abs() < lineHeight / 2;
    markNeedsPaint();
    _scheduleNotifyEditableRect();
  }

  void _onFocusChange() {
    markNeedsPaint();
  }

  void _onTerminalChange() {
    final usingAlt = _terminal.isUsingAltBuffer;
    if (usingAlt != _wasUsingAltBuffer) {
      _wasUsingAltBuffer = usingAlt;
      // Always snap to the bottom when switching buffers.
      // Do NOT jumpTo(0) here: the new _effectiveScrollPixels logic makes the
      // alt buffer render at the scroll-bottom (stickToBottom position), so a
      // forced jump to 0 would briefly show the oldest main-buffer history.
      _stickToBottom = true;
    }
    // Show cursor at the new position immediately when typing/output arrives.
    _cursorBlinkPhase = true;
    markNeedsLayout();
    markNeedsPaint();
    _scheduleNotifyEditableRect();
  }

  void _onControllerUpdate() {
    markNeedsLayout();
  }

  @override
  final isRepaintBoundary = true;

  void _restartBlinkTimer() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
    if (!_cursorBlink) {
      _cursorBlinkPhase = true;
      return;
    }
    _cursorBlinkPhase = true;
    _blinkTimer = Timer.periodic(
      Duration(milliseconds: _cursorBlinkPeriodMs),
      (_) {
        _cursorBlinkPhase = !_cursorBlinkPhase;
        markNeedsPaint();
      },
    );
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _wasUsingAltBuffer = _terminal.isUsingAltBuffer;
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
    _restartBlinkTimer();
  }

  @override
  void detach() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    _updateViewportSize();

    _updateScrollOffset();

    if (_stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _offset.pixels);
    }
  }

  /// Total height of the terminal in pixels. Includes scrollback buffer.
  ///
  /// When in alt buffer, we use the main buffer's line count so the Scrollable
  /// has scrollable range for history (like xterm/tabby: scrolling while in
  /// alt buffer shows the main-buffer session history).
  double get _terminalHeight {
    final buf = _terminal.isUsingAltBuffer
        ? _terminal.mainBuffer
        : _terminal.buffer;
    return buf.lines.length * _painter.cellSize.height;
  }

  /// Current scroll position in pixels (smooth sub-line scrolling).
  double get _scrollPixels => _offset.pixels;

  /// Effective scroll offset used for painting.
  ///
  /// When in alt buffer AND stuck to the bottom: return 0 so the alt buffer
  /// content is rendered from its own line 0 (the TUI fills the viewport).
  /// Otherwise (normal mode OR scrolled into main-buffer history): return the
  /// real pixel offset so the correct main-buffer lines are painted.
  double get _effectiveScrollPixels {
    if (_terminal.isUsingAltBuffer && _stickToBottom) {
      return 0.0;
    }
    return _scrollPixels;
  }

  /// The height of a terminal line in pixels. This includes the line spacing.
  /// Height of the entire terminal is expected to be a multiple of this value.
  double get lineHeight => _painter.cellSize.height;

  /// Top-left of [row] in this render object's paint coordinates.
  Offset _cellTopLeft(int col, int row) {
    return Offset(
      col * _painter.cellSize.width,
      row * _painter.cellSize.height + _lineOffset,
    );
  }

  /// Get the top-left corner of the cell at [cellOffset] in pixels.
  Offset getOffset(CellOffset cellOffset) {
    return _cellTopLeft(cellOffset.x, cellOffset.y);
  }

  /// Get the [CellOffset] of the cell that [offset] is in.
  CellOffset getCellOffset(Offset offset) {
    final x = offset.dx;
    final y = offset.dy - _padding.top + _effectiveScrollPixels;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  /// Selects entire words in the terminal that contains [from] and [to].
  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = getCellOffset(from);
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = getCellOffset(to);
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  void selectCharacters(Offset from, [Offset? to]) {
    final fromPosition = getCellOffset(from);
    selectCharactersFromCellOffset(
      fromPosition,
      to == null ? null : getCellOffset(to),
    );
  }

  /// Selects characters in the terminal from a stable buffer cell offset.
  /// Useful while autoscrolling, where the original screen offset no longer
  /// maps to the same buffer line after the viewport moves.
  void selectCharactersFromCellOffset(CellOffset fromPosition,
      [CellOffset? toPosition]) {
    if (toPosition == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(fromPosition),
      );
    } else {
      if (toPosition.x >= fromPosition.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(toPosition),
      );
    }
  }

  /// Send a mouse event at [offset] with [button] being currently in [buttonState].
  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    bool motion = false,
  }) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(
      button,
      buttonState,
      position,
      shift: shift,
      alt: alt,
      ctrl: ctrl,
      motion: motion,
    );
  }

  /// [localToGlobal] must not run during layout; defer to after the frame.
  void _scheduleNotifyEditableRect() {
    if (_onEditableRect == null || _editableRectUpdateScheduled || !attached) {
      return;
    }
    _editableRectUpdateScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _editableRectUpdateScheduled = false;
      if (!attached) return;
      _notifyEditableRect();
    });
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  /// Update the viewport size in cells based on the current widget size in
  /// pixels.
  void _updateViewportSize() {
    if (size <= _painter.cellSize) {
      return;
    }

    final viewportSize = TerminalSize(
      size.width ~/ _painter.cellSize.width,
      _viewportHeight ~/ _painter.cellSize.height,
    );

    if (_viewportSize != viewportSize) {
      _viewportSize = viewportSize;
      _resizeTerminalIfNeeded();
    }
  }

  /// Notify the underlying terminal that the viewport size has changed.
  void _resizeTerminalIfNeeded() {
    if (_autoResize && _viewportSize != null) {
      _terminal.resize(
        _viewportSize!.width,
        _viewportSize!.height,
        _painter.cellSize.width.round(),
        _painter.cellSize.height.round(),
      );
    }
  }

  /// Update the scroll offset based on the current terminal state. This should
  /// be called in [performLayout] after the viewport size has been updated.
  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText {
    return _composingText != null && _composingText!.isNotEmpty;
  }

  bool get _shouldShowCursor {
    return _terminal.cursorVisibleMode || _alwaysShowCursor || _isComposingText;
  }

  bool get _paintCursorNow {
    if (!_shouldShowCursor) return false;
    if (!_cursorBlink || !_focusNode.hasFocus) return true;
    return _cursorBlinkPhase;
  }

  double get _viewportHeight {
    return size.height - _padding.vertical;
  }

  double get _maxScrollExtent {
    final maxExtent = _terminalHeight - _viewportHeight;

    final lineHeight = _painter.cellSize.height;
    final adjustedMaxExtent = (maxExtent / lineHeight).ceil() * lineHeight;

    return max(0.0, adjustedMaxExtent);
  }

  double get _lineOffset {
    return -_effectiveScrollPixels + _padding.top;
  }

  /// The offset of the cursor from the top left corner of this render object.
  Offset get cursorOffset {
    return getOffset(
      CellOffset(
        _terminal.buffer.cursorX,
        _terminal.buffer.absoluteCursorY,
      ),
    );
  }

  Size get cellSize {
    return _painter.cellSize;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.save();
    context.canvas.clipRect(offset & size);
    _paint(context, offset);
    context.canvas.restore();
    context.setWillChangeHint();
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;

    // When the user has scrolled up from the alt-buffer bottom into main-buffer
    // history, render the main buffer at the current scroll position instead of
    // the alt buffer.  At stickToBottom (the default while in alt buffer),
    // always render the alt buffer so the TUI app fills the viewport.
    final isScrollingHistory = _terminal.isUsingAltBuffer && !_stickToBottom;
    final lines = isScrollingHistory
        ? _terminal.mainBuffer.lines
        : _terminal.buffer.lines;

    final charHeight = _painter.cellSize.height;

    final firstLineOffset = _effectiveScrollPixels - _padding.top;
    final lastLineOffset =
        _effectiveScrollPixels + size.height - _padding.bottom;

    final firstLine = (firstLineOffset / charHeight).floor();
    final lastLine = (lastLineOffset / charHeight).ceil() - 1;

    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);

    // Selection and highlights only apply to the active buffer view.
    if (!isScrollingHistory) {
      if (_controller.selection != null) {
        _paintSelection(
          context,
          offset,
          canvas,
          _controller.selection!,
          effectFirstLine,
          effectLastLine,
        );
      }

      _paintHighlights(
        context,
        offset,
        canvas,
        _controller.highlights,
        effectFirstLine,
        effectLastLine,
      );
    }

    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLine(
        canvas,
        offset + _cellTopLeft(0, i),
        lines[i],
      );
    }

    // Cursor and composing text only make sense when showing the active buffer.
    if (!isScrollingHistory) {
      if (_terminal.buffer.absoluteCursorY >= effectFirstLine &&
          _terminal.buffer.absoluteCursorY <= effectLastLine) {
        if (_isComposingText) {
          _paintComposingText(canvas, offset + cursorOffset);
        }

        if (_paintCursorNow) {
          _painter.paintCursor(
            canvas,
            offset + cursorOffset,
            cursorType: _cursorType,
            hasFocus: _focusNode.hasFocus,
          );
        }
      }
    }
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
      underline: true,
    );

    final builder = ParagraphBuilder(
      _painter.textStyle.toParagraphStyle(
        color: style.color,
        backgroundColor: style.backgroundColor,
        underline: true,
      ),
    );
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(
      style.getTextStyle(textScaler: _painter.textScaler),
    );
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: size.width));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
  }

  void _paintSelection(
    PaintingContext context,
    Offset paintOffset,
    Canvas canvas,
    BufferRange selection,
    int firstLine,
    int lastLine,
  ) {
    for (final segment in selection.toSegments()) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }

      if (segment.line < firstLine) {
        continue;
      }

      if (segment.line > lastLine) {
        break;
      }

      _paintSegment(paintOffset, canvas, segment, _painter.theme.selection);
    }
  }

  void _paintHighlights(
    PaintingContext context,
    Offset paintOffset,
    Canvas canvas,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (var highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (var segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(paintOffset, canvas, segment, highlight.color);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _paintSegment(
    Offset paintOffset,
    Canvas canvas,
    BufferSegment segment,
    Color color,
  ) {
    final start = segment.start ?? 0;
    final end = segment.end ?? _terminal.viewWidth;

    _painter.paintHighlight(
      canvas,
      paintOffset + _cellTopLeft(start, segment.line),
      end - start,
      color,
    );
  }
}
