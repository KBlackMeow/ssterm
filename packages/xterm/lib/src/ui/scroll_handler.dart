import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/core/input/handler.dart';

/// Handles scrolling gestures in the alternate screen buffer. In alternate
/// screen buffer, the terminal don't have a scrollback buffer, instead, the
/// scroll gestures are converted to escape sequences based on the current
/// report mode declared by the application.
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

  /// Returns the cell offset for the pixel offset.
  final CellOffset Function(Offset) getCellOffset;

  /// Returns the pixel height of lines in the terminal.
  final double Function() getLineHeight;

  /// Whether to simulate scroll events in the terminal when the application
  /// doesn't declare it supports mouse wheel events. true by default as it
  /// is the default behavior of most terminals.
  final bool simulateScroll;

  /// Called when the user starts interacting with the scroll view.
  final VoidCallback? onInteraction;

  final Widget child;

  @override
  State<TerminalScrollGestureHandler> createState() =>
      _TerminalScrollGestureHandlerState();
}

class _TerminalScrollGestureHandlerState
    extends State<TerminalScrollGestureHandler> {
  /// Whether the application is in alternate screen buffer. If false, then this
  /// widget does nothing.
  var isAltBuffer = false;

  /// Accumulated vertical scroll distance in pixels (trackpad / drag).
  double _scrollPixelOffset = 0;

  /// The variable that tracks the line offset in last scroll event. Used to
  /// determine how many the scroll events should be sent to the terminal.
  var lastLineOffset = 0;

  /// Accumulated line delta not yet written to the PTY.
  /// Flushed by [_flushScrollDelta] via a short timer so that all
  /// PointerScrollEvents that land within the debounce window are coalesced
  /// into one PTY write.  Without this, each event triggers a separate write
  /// and vim redraws between keys, leaving DECRC-restored underline attrs on
  /// newly drawn lines — visible as stripe artifacts at small font sizes on
  /// local (zero-latency) PTYs.  SSH avoids this naturally because network
  /// buffering already batches the writes at the server side.
  int _pendingLineDelta = 0;
  Timer? _scrollFlushTimer;

  /// This variable tracks the last offset where the scroll gesture started.
  /// Used to calculate the cell offset of the terminal mouse event.
  var lastPointerPosition = Offset.zero;

  @override
  void initState() {
    widget.terminal.addListener(_onTerminalUpdated);
    isAltBuffer = widget.terminal.isUsingAltBuffer;
    super.initState();
  }

  @override
  void dispose() {
    _scrollFlushTimer?.cancel();
    widget.terminal.removeListener(_onTerminalUpdated);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalScrollGestureHandler oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdated);
      widget.terminal.addListener(_onTerminalUpdated);
      isAltBuffer = widget.terminal.isUsingAltBuffer;
    }
    super.didUpdateWidget(oldWidget);
  }

  void _resetScrollTracking() {
    _scrollPixelOffset = 0;
    lastLineOffset = 0;
    _pendingLineDelta = 0;
    _scrollFlushTimer?.cancel();
    _scrollFlushTimer = null;
  }

  void _onTerminalUpdated() {
    if (isAltBuffer != widget.terminal.isUsingAltBuffer) {
      if (widget.terminal.isUsingAltBuffer) {
        _resetScrollTracking();
      }
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      setState(() {});
    }
  }

  /// Send a single scroll event to the terminal. If [simulateScroll] is true,
  /// then if the application doesn't recognize mouse wheel events, this method
  /// will simulate scroll events by sending up/down arrow keys.
  void _applyLineDelta(int delta) {
    if (delta == 0) return;

    widget.onInteraction?.call();

    final up = delta < 0;
    final count = delta.abs();
    final position = widget.getCellOffset(lastPointerPosition);

    var mouseHandled = false;
    for (var i = 0; i < count; i++) {
      if (widget.terminal.mouseInput(
        up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        position,
      )) {
        mouseHandled = true;
      }
    }

    if (mouseHandled || !widget.simulateScroll) {
      return;
    }

    // Coalesce arrow keys into one PTY write. Sending them separately (common
    // on local PTY with fast trackpad input) makes vim redraw between keys and
    // can leave DECRC-restored underline attrs on newly drawn lines. SSH is
    // naturally throttled by latency so it rarely hit this.
    final handler = widget.terminal.inputHandler ?? defaultInputHandler;
    final keys = <String>[];
    final key = up ? TerminalKey.arrowUp : TerminalKey.arrowDown;
    for (var i = 0; i < count; i++) {
      final output = handler.call(
        TerminalKeyboardEvent(
          key: key,
          shift: false,
          ctrl: false,
          alt: false,
          state: widget.terminal,
          altBuffer: widget.terminal.isUsingAltBuffer,
          platform: widget.terminal.platform,
        ),
      );
      if (output != null) {
        keys.add(output);
      }
    }

    if (keys.isNotEmpty) {
      widget.terminal.onOutput?.call(keys.join());
    }
  }

  void _handleScrollPixels(double deltaPixels) {
    final lineHeight = widget.getLineHeight();
    if (lineHeight <= 0 || deltaPixels == 0) return;

    _scrollPixelOffset += deltaPixels;
    final currentLineOffset = _scrollPixelOffset ~/ lineHeight;
    final lineDelta = currentLineOffset - lastLineOffset;
    lastLineOffset = currentLineOffset;

    if (lineDelta == 0) return;
    _pendingLineDelta += lineDelta;

    final debounceMs = widget.terminal.compat.altScrollDebounceMs;
    if (debounceMs <= 0) {
      _flushScrollDelta();
      return;
    }
    _scrollFlushTimer ??=
        Timer(Duration(milliseconds: debounceMs), _flushScrollDelta);
  }

  /// Writes the accumulated scroll delta to the PTY as a single string.
  /// When [TerminalCompat.altScrollDebounceMs] is non-zero, coalesces rapid
  /// wheel events into one PTY write so vim does not redraw between keys.
  void _flushScrollDelta() {
    _scrollFlushTimer = null;
    final delta = _pendingLineDelta;
    _pendingLineDelta = 0;
    _applyLineDelta(delta);
  }

  @override
  Widget build(BuildContext context) {
    if (!isAltBuffer) {
      return widget.child;
    }

    // Do not wrap in a Scrollable here: translating the terminal widget while
    // the buffer paint origin stays fixed misaligns rows so cell underlines
    // appear on the wrong glyphs (especially in short panes).
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          lastPointerPosition = event.position;
          _handleScrollPixels(event.scrollDelta.dy);
        }
      },
      onPointerDown: (event) {
        lastPointerPosition = event.position;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (details) {
          _handleScrollPixels(-details.delta.dy);
        },
        child: widget.child,
      ),
    );
  }
}
