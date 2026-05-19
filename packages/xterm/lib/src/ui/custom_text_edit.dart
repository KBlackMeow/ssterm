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
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (!_isImeComposing) {
      final result = widget.onKeyEvent(focusNode, event);
      // KeyRepeatEvent for plain chars (e.g. a-z) returns ignored because
      // keyInput() has no keytab entry for them without a modifier. On some
      // platforms the TextInput channel stops forwarding updateEditingValue
      // after our setEditingState("") reset, so repeats never arrive. Handle
      // them directly here, mirroring CustomKeyboardListener's behaviour.
      if (result == KeyEventResult.ignored &&
          event is KeyRepeatEvent &&
          event.character != null &&
          event.character!.isNotEmpty) {
        widget.onInsert(event.character!);
        return KeyEventResult.handled;
      }
      return result;
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);

      _connection!.show();

      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  /// Non-null while an IME composition is in progress (CJK, etc.).
  String? _imeComposingText;

  TextEditingValue? _lastEditingState;

  bool get _isImeComposing =>
      _imeComposingText != null ||
      _currentEditingState.composing.start !=
          _currentEditingState.composing.end;

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
    if (value.composing.start != value.composing.end) {
      // Extract only the composing portion using the composing range so that
      // any previously committed prefix in the field is not included.
      final start = value.composing.start.clamp(0, value.text.length);
      final end = value.composing.end.clamp(0, value.text.length);
      _imeComposingText = value.text.substring(start, end);
      widget.onComposing(_imeComposingText);
      _lastEditingState = value;
      return;
    }

    final imePreview = _imeComposingText;
    final hadImeComposing = imePreview != null;

    if (hadImeComposing) {
      _imeComposingText = null;
      widget.onComposing(null);

      // The committed text is the full value.text — the platform resets its
      // field to the init state after each IME commit, so value.text contains
      // only the newly committed characters (not accumulated prior commits).
      final committed = value.text;
      if (committed.length < _initEditingState.text.length) {
        widget.onDelete();
      } else if (committed.isNotEmpty) {
        widget.onInsert(committed);
      }

      _lastEditingState = _initEditingState.copyWith();
      if (committed.isNotEmpty) {
        _currentEditingState = _initEditingState.copyWith();
        _connection?.setEditingState(_initEditingState);
      }
      return;
    }

    var inputText = value.text;

    // Avoid duplicate chars when the platform sends cumulative text (e.g. "l"
    // then "ls"); still allows multi-char CJK commits in one chunk.
    if (_lastEditingState?.text.isNotEmpty == true &&
        inputText.length > _lastEditingState!.text.length) {
      inputText = inputText.substring(_lastEditingState!.text.length);
    }

    if (value.text.length < _initEditingState.text.length) {
      widget.onDelete();
    } else if (inputText.isNotEmpty) {
      widget.onInsert(inputText);
    }

    _lastEditingState = value;

    if (value != _initEditingState && inputText.isNotEmpty) {
      _currentEditingState = _initEditingState.copyWith();
      _connection?.setEditingState(_initEditingState);
      _lastEditingState = _initEditingState.copyWith();
    }
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
    // print('connectionClosed');
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
