import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  static const _autoScrollInterval = Duration(milliseconds: 16);
  static const _autoScrollEdgeExtent = 28.0;
  static const _autoScrollMaxLinesPerTick = 3.0;

  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  Offset _terminalLocal(Offset global) => renderTerminal.globalToLocal(global);

  CellOffset? _dragStartCellOffset;

  LongPressStartDetails? _lastLongPressStartDetails;

  Offset? _lastDragGlobalPosition;

  Timer? _autoScrollTimer;

  @override
  void dispose() {
    _stopAutoScroll(clearDragState: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      child: widget.child,
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onSecondaryTapDown,
      onTertiaryTapUp: onSecondaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      // onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: (_) => _stopAutoScroll(clearDragState: true),
      onDragCancel: () => _stopAutoScroll(clearDragState: true),
      onDoubleTapDown: onDoubleTapDown,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.right);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(_terminalLocal(details.globalPosition));
  }

  void onLongPressStart(LongPressStartDetails details) {
    _lastLongPressStartDetails = details;
    renderTerminal.selectWord(_terminalLocal(details.globalPosition));
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    renderTerminal.selectWord(
      _terminalLocal(_lastLongPressStartDetails!.globalPosition),
      _terminalLocal(details.globalPosition),
    );
  }

  // void onLongPressUp() {}

  void onDragStart(DragStartDetails details) {
    _lastDragGlobalPosition = details.globalPosition;
    final local = _terminalLocal(details.globalPosition);
    _dragStartCellOffset = renderTerminal.getCellOffset(local);

    details.kind == PointerDeviceKind.mouse
        ? renderTerminal.selectCharactersFromCellOffset(_dragStartCellOffset!)
        : renderTerminal.selectWord(local);
    _updateAutoScroll(local);
  }

  void onDragUpdate(DragUpdateDetails details) {
    _lastDragGlobalPosition = details.globalPosition;
    _updateDragSelection();
    _updateAutoScroll(_terminalLocal(_lastDragGlobalPosition!));
  }

  void _updateAutoScroll(Offset localPosition) {
    if (_autoScrollDelta(localPosition) == 0) {
      _stopAutoScroll();
      return;
    }

    _autoScrollTimer ??= Timer.periodic(
      _autoScrollInterval,
      (_) => _autoScrollSelection(),
    );
  }

  double _autoScrollDelta(Offset localPosition) {
    final height = renderTerminal.size.height;
    if (height <= 0) {
      return 0;
    }

    final lineHeight = renderTerminal.lineHeight;
    if (lineHeight <= 0) {
      return 0;
    }

    final overscroll = localPosition.dy < _autoScrollEdgeExtent
        ? localPosition.dy - _autoScrollEdgeExtent
        : localPosition.dy > height - _autoScrollEdgeExtent
            ? localPosition.dy - height + _autoScrollEdgeExtent
            : 0.0;

    if (overscroll == 0) {
      return 0;
    }

    final lines = (overscroll.abs() / _autoScrollEdgeExtent).clamp(
      0.25,
      _autoScrollMaxLinesPerTick,
    );
    return overscroll.sign * lineHeight * lines;
  }

  void _autoScrollSelection() {
    final dragStartCell = _dragStartCellOffset;
    final dragPosition = _lastDragGlobalPosition;
    if (dragStartCell == null || dragPosition == null) {
      _stopAutoScroll(clearDragState: true);
      return;
    }

    final delta = _autoScrollDelta(_terminalLocal(dragPosition));
    if (delta == 0 || !terminalView.scrollBy(delta)) {
      _stopAutoScroll();
      return;
    }

    _updateDragSelection();
  }

  void _updateDragSelection() {
    final dragStartCell = _dragStartCellOffset;
    final dragPosition = _lastDragGlobalPosition;
    if (dragStartCell == null || dragPosition == null) {
      return;
    }

    renderTerminal.selectCharactersFromCellOffset(
      dragStartCell,
      renderTerminal.getCellOffset(_terminalLocal(dragPosition)),
    );
  }

  void _stopAutoScroll({bool clearDragState = false}) {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (clearDragState) {
      _lastDragGlobalPosition = null;
      _dragStartCellOffset = null;
    }
  }
}
