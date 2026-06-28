import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';

/// Handles scrolling in the alternate screen buffer.
///
/// When the active app has mouse reporting enabled (mouseMode.reportScroll),
/// trackpad and mouse-wheel events are translated into terminal mouse-wheel
/// escape sequences and forwarded to the PTY. This gives vim, less, and other
/// TUI apps precise 1-event-per-N-lines control via their own scroll bindings.
///
/// When the app has no mouse reporting (mouseMode.none / clickOnly), this
/// widget is a no-op and the parent [Scrollable] handles the gesture,
/// scrolling through the main-buffer session history.
class TerminalScrollGestureHandler extends StatefulWidget {
  const TerminalScrollGestureHandler({
    super.key,
    required this.terminal,
    required this.getCellOffset,
    required this.getLineHeight,
    this.simulateScroll = true,
    this.onInteraction,
    required this.child,
  });

  final Terminal terminal;
  final CellOffset Function(Offset) getCellOffset;
  final double Function() getLineHeight;

  /// Fall back to arrow-key simulation when the app does not handle mouse
  /// wheel events. Enabled by default (matches xterm behaviour).
  final bool simulateScroll;

  final VoidCallback? onInteraction;
  final Widget child;

  @override
  State<TerminalScrollGestureHandler> createState() =>
      _TerminalScrollGestureHandlerState();
}

class _TerminalScrollGestureHandlerState
    extends State<TerminalScrollGestureHandler> {
  var _isAltBuffer = false;
  MouseMode _mouseMode = MouseMode.none;

  // Trackpad: sub-line accumulator for 0.3× rate limiting (xterm.js algorithm).
  double _trackpadPartial = 0;
  // Mouse wheel: sub-line accumulator (1:1 with scroll delta / lineHeight).
  double _mousePartial = 0;

  int _pendingLineDelta = 0;
  Timer? _flushTimer;

  // Device pixel ratio: panDelta.dy is in physical px; divide to get logical px.
  double _dpr = 1.0;

  var _lastPointerPosition = Offset.zero;

  // ── lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminalChanged);
    _isAltBuffer = widget.terminal.isUsingAltBuffer;
    _mouseMode = widget.terminal.mouseMode;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    widget.terminal.removeListener(_onTerminalChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalScrollGestureHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
      _isAltBuffer = widget.terminal.isUsingAltBuffer;
      _mouseMode = widget.terminal.mouseMode;
    }
  }

  // ── terminal state tracking ────────────────────────────────────────────────

  void _onTerminalChanged() {
    final alt = widget.terminal.isUsingAltBuffer;
    final mode = widget.terminal.mouseMode;
    if (alt == _isAltBuffer && mode == _mouseMode) return;

    // Reset scroll state when entering alt buffer (app is starting fresh).
    if (alt && alt != _isAltBuffer) _resetAccumulators();

    _isAltBuffer = alt;
    _mouseMode = mode;
    setState(() {});
  }

  void _resetAccumulators() {
    _trackpadPartial = 0;
    _mousePartial = 0;
    _pendingLineDelta = 0;
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  // ── scroll logic ───────────────────────────────────────────────────────────

  /// Precision trackpad (PointerPanZoomUpdate).
  void _handleTrackpad(double logicalDy) {
    final lh = widget.getLineHeight();
    if (lh <= 0 || logicalDy == 0) return;

    _trackpadPartial += logicalDy / lh;
    final lines = _trackpadPartial.truncate();
    if (lines == 0) return;
    _trackpadPartial -= lines;

    _pendingLineDelta += lines;
    _scheduleFlush();
  }

  /// Physical mouse wheel (PointerScrollEvent).
  void _handleMouseWheel(double physicalDy) {
    final lh = widget.getLineHeight();
    if (lh <= 0 || physicalDy == 0) return;

    _mousePartial += physicalDy / lh;
    final lines = _mousePartial.truncate();
    if (lines == 0) return;
    _mousePartial -= lines;

    _pendingLineDelta += lines;
    _scheduleFlush();
  }

  void _scheduleFlush() {
    final ms = widget.terminal.compat.altScrollDebounceMs;
    if (ms <= 0) {
      _flushPending();
    } else {
      _flushTimer ??= Timer(Duration(milliseconds: ms), _flushPending);
    }
  }

  void _flushPending() {
    _flushTimer = null;
    final delta = _pendingLineDelta;
    _pendingLineDelta = 0;
    if (delta != 0) _applyDelta(delta);
  }

  /// Send [delta] scroll lines to the terminal.
  ///
  /// Tries mouse-wheel escape sequences first (preferred: lets the app map
  /// the event to however many visual lines it likes). Falls back to arrow
  /// keys only when the app has not enabled any mouse reporting — this
  /// simulates scrolling for apps like `less` without mouse support.
  void _applyDelta(int delta) {
    widget.onInteraction?.call();

    final up = delta < 0;
    final count = delta.abs();
    final pos = widget.getCellOffset(_lastPointerPosition);

    // Mouse-wheel escape sequences (e.g. \e[<65;col;rowM in SGR mode).
    var mouseHandled = false;
    for (var i = 0; i < count; i++) {
      if (widget.terminal.mouseInput(
        up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        pos,
      )) {
        mouseHandled = true;
      }
    }
    if (mouseHandled || !widget.simulateScroll) return;

    // Arrow-key fallback for apps without mouse reporting (less, man, etc.).
    final handler = widget.terminal.inputHandler ?? defaultInputHandler;
    final key = up ? TerminalKey.arrowUp : TerminalKey.arrowDown;
    final buf = StringBuffer();
    for (var i = 0; i < count; i++) {
      final out = handler.call(TerminalKeyboardEvent(
        key: key,
        shift: false,
        ctrl: false,
        alt: false,
        state: widget.terminal,
        altBuffer: widget.terminal.isUsingAltBuffer,
        platform: widget.terminal.platform,
      ));
      if (out != null) buf.write(out);
    }
    if (buf.isNotEmpty) widget.terminal.onOutput?.call(buf.toString());
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.of(context).devicePixelRatio;

    // Only intercept when in alt buffer AND the app has scroll reporting.
    // For none / clickOnly: let the Scrollable show main-buffer history.
    if (!_isAltBuffer || !_mouseMode.reportScroll) {
      return widget.child;
    }

    // Listener fires before the gesture arena, so the inner Scrollable
    // (NeverScrollableScrollPhysics) cannot consume events before we see them.
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _lastPointerPosition = event.localPosition;
          _handleMouseWheel(event.scrollDelta.dy);
        }
      },
      onPointerDown: (event) {
        _lastPointerPosition = event.localPosition;
      },
      onPointerPanZoomStart: (event) {
        _lastPointerPosition = event.localPosition;
        _trackpadPartial = 0;
      },
      onPointerPanZoomUpdate: (event) {
        _lastPointerPosition = event.localPosition;
        _handleTrackpad(-event.panDelta.dy / _dpr);
      },
      child: widget.child,
    );
  }
}
