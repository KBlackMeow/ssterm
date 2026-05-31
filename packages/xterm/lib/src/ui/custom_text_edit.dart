import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;
  int? _viewId;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _viewId = View.of(context).viewId;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
      // After requesting focus, open connection in the next frame so
      // _onFocusChange has time to fire first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.focusNode.hasFocus) {
          _openInputConnection();
        }
      });
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _safeSetEditingState(value);
  }

  void _safeSetEditingState(TextEditingValue value) {
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    try {
      connection.setEditingState(value);
    } on PlatformException {
      // Native client already torn down (common during Windows IME commit).
      _handleDeadConnection();
    }
  }

  void _safeUpdateEditableGeometry(Rect rect, Rect caretRect) {
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    try {
      connection.setEditableSizeAndTransform(
        rect.size,
        Matrix4.translationValues(rect.left, rect.top, 0),
      );
      connection.setCaretRect(caretRect.shift(Offset(-rect.left, -rect.top)));
    } on PlatformException {
      _handleDeadConnection();
    }
  }

  void _handleDeadConnection() {
    _connection = null;
    _composingActive = false;
    _scheduleReconnectInput();
  }

  void _scheduleReconnectInput() {
    if (!mounted || !widget.focusNode.hasFocus || !_shouldCreateInputConnection) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.focusNode.hasFocus && !hasInputConnection) {
        _openInputConnection();
      }
    });
  }

  bool get _resetEditingStateAfterInput =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// Resets the hidden field after input. Deferred on Windows so IME commit does
  /// not call setEditingState re-entrantly while the native client is busy.
  void _resetHiddenFieldAfterInput() {
    _currentEditingState = _initEditingState.copyWith();
    _lastEditingState = _initEditingState.copyWith();
    if (_resetEditingStateAfterInput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.focusNode.hasFocus) return;
        if (!hasInputConnection) {
          _openInputConnection();
          return;
        }
        _safeSetEditingState(_initEditingState);
      });
    } else {
      _safeSetEditingState(_initEditingState);
    }
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    _safeUpdateEditableGeometry(rect, caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (_composingActive || !_currentEditingState.composing.isCollapsed) {
      return KeyEventResult.skipRemainingHandlers;
    }

    final result = widget.onKeyEvent(focusNode, event);
    // Windows/Linux: printable keys may arrive only via KeyEvent when the
    // TextInput channel stalls after setEditingState; also used for repeats.
    if (result == KeyEventResult.ignored &&
        event is! KeyUpEvent &&
        event.character != null &&
        event.character!.isNotEmpty) {
      final isApple = defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS;
      if (!isApple || event is KeyRepeatEvent) {
        widget.onInsert(event.character!);
        return KeyEventResult.handled;
      }
    }
    return result;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus) {
      // Skip consumeKeyboardToken() — terminal always wants the keyboard when
      // focused, regardless of how focus was obtained (autofocus, tap, API call).
      widget.focusNode.consumeKeyboardToken(); // consume to keep token state clean
      _openInputConnection();
    } else {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (_viewId == null) {
      _scheduleReconnectInput();
      return;
    }

    if (hasInputConnection) {
      _connection!.show();
      return;
    }

    final config = TextInputConfiguration(
      viewId: _viewId,
      inputType: widget.inputType,
      inputAction: widget.inputAction,
      keyboardAppearance: widget.keyboardAppearance,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
    );

    try {
      _connection = TextInput.attach(this, config);
      _connection!.show();
      _safeSetEditingState(_initEditingState);
      _lastEditingState = _initEditingState.copyWith();
    } on PlatformException {
      _connection = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.focusNode.hasFocus) {
          _openInputConnection();
        }
      });
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  TextEditingValue get _initEditingState {
    // On Windows/Linux, setEditingState("") causes the TextInput channel to
    // stop forwarding updateEditingValue, breaking IME input entirely.
    // Use a non-empty sentinel so the channel stays active after each reset.
    final usesSentinel = widget.deleteDetection ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    return usesSentinel
        ? const TextEditingValue(
            text: '  ',
            selection: TextSelection.collapsed(offset: 2),
          )
        : const TextEditingValue(
            text: '',
            selection: TextSelection.collapsed(offset: 0),
          );
  }

  late var _currentEditingState = _initEditingState.copyWith();

  TextEditingValue? _lastEditingState;

  /// True after [onComposing] was called with non-null preview text.
  bool _composingActive = false;

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentEditingState = value;

    // IME is still composing — show preview only, do not send to the shell.
    if (!value.composing.isCollapsed) {
      final preview = value.composing.textInside(value.text);
      _composingActive = preview.isNotEmpty;
      widget.onComposing(preview.isEmpty ? null : preview);
      _lastEditingState = value;
      return;
    }

    final last = _lastEditingState;
    final wasComposing =
        _composingActive || (last != null && !last.composing.isCollapsed);

    // IME commit: pinyin shrinks to hanzi — must not treat as backspace.
    if (wasComposing) {
      _composingActive = false;
      widget.onComposing(null);
      final committed = _extractImeCommit(value);
      if (committed.isNotEmpty) {
        widget.onInsert(committed);
      }
      _resetHiddenFieldAfterInput();
      return;
    }

    widget.onComposing(null);

    if (last != null && value.text.length < last.text.length) {
      widget.onDelete();
      if (value.text != _initEditingState.text) {
        _resetHiddenFieldAfterInput();
      } else {
        _lastEditingState = value;
      }
      return;
    }

    final textDelta = _extractTextDelta(value, last);
    if (textDelta.isNotEmpty) {
      widget.onInsert(textDelta);
    }

    if (value.text != _initEditingState.text) {
      _resetHiddenFieldAfterInput();
    } else {
      _lastEditingState = value;
    }
  }

  /// Text committed when an IME composition ends.
  String _extractImeCommit(TextEditingValue value) {
    final initText = _initEditingState.text;
    var committed = value.text;
    if (initText.isNotEmpty && committed.startsWith(initText)) {
      committed = committed.substring(initText.length);
    }
    return committed;
  }

  /// Extracts newly typed text from [value], accounting for cumulative updates
  /// ("  a" → "  ab") and full-field replacement ("  " → "a") on Windows.
  String _extractTextDelta(TextEditingValue value, TextEditingValue? last) {
    final text = value.text;
    final initText = _initEditingState.text;
    final initLen = initText.length;

    if (last != null &&
        text.length > last.text.length &&
        text.startsWith(last.text)) {
      return text.substring(last.text.length);
    }

    if (initLen > 0 && text.length > initLen && text.startsWith(initText)) {
      return text.substring(initLen);
    }

    // Windows often replaces the whole field with just the new character(s).
    if (last != null &&
        last.text == initText &&
        text.isNotEmpty &&
        text != initText) {
      return text;
    }

    return '';
  }

  @override
  void performAction(TextInputAction action) {
    // print('performAction $action');
    widget.onAction(action);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    _connection = null;
    _scheduleReconnectInput();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
