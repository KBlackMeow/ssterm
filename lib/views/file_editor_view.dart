import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';

import '../services/file_write_service.dart';
import '../widgets/frosted_glass.dart';
import 'file_editor_language.dart';

const _kBg = Color(0xFF1E1E1E);
const _kToolbar = Color(0x66252525);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgDim = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);
const _kDanger = Color(0xFFFF6E67);

/// Syntax-highlighted editor tab for a remote file opened from the SFTP
/// panel. I/O goes entirely through [SftpFileSystemAdapter] — no AI
/// Agent involvement, no LLM-facing envelopes; every error string here
/// is written for a human reading the toolbar.
///
/// Highlighting/line-numbers/folding come from `flutter_code_editor`'s
/// [CodeController] (a [TextEditingController] subclass) and [CodeField].
/// IMPORTANT: [CodeController.text] returns only the VISIBLE text when
/// code is folded — every place below that reads or replaces the full
/// buffer uses [CodeController.fullText] instead, so a folded save (or
/// a reload) can never silently drop the folded-away content.
class FileEditorView extends StatefulWidget {
  const FileEditorView({
    super.key,
    required this.path,
    required this.sftp,
    required this.label,
    required this.initialContent,
    required this.initialMtime,
    required this.dirty,
  });

  /// Remote absolute path being edited.
  final String path;

  /// SFTP client borrowed from the source SSH tab — see
  /// `AppTab.editorSftp`'s doc comment for the ownership/staleness
  /// contract this widget relies on.
  final SftpClient sftp;

  /// Display label for the source connection, used in error text.
  final String label;

  /// Content loaded by the SFTP panel BEFORE this tab was created —
  /// used once, in [State.initState], to seed the [CodeController].
  final String initialContent;

  /// mtime captured alongside [initialContent] — the initial concurrency
  /// token for [FileEditorViewState.save].
  final DateTime? initialMtime;

  /// Mirror of the buffer's dirty state, owned by the host `AppTab` (see
  /// `AppTab.editorDirty`) so the tab-close confirmation gate can read it
  /// without needing this widget mounted.
  final ValueNotifier<bool> dirty;

  @override
  State<FileEditorView> createState() => FileEditorViewState();
}

enum _ConflictChoice { overwrite, reload }

/// Editor scroll behavior: clamp at the edges instead of macOS's default
/// rubber-band overscroll, so scrolling stops dead at the top/bottom and
/// left/right of the code area.
///
/// This must override [ScrollBehavior.getScrollPhysics] rather than setting
/// `physics:` on a copy — macOS's platform branch would otherwise wrap the
/// clamped physics as the *parent* of a `BouncingScrollPhysics`, and the
/// rubber band would still show.
class _ClampingScrollBehavior extends MaterialScrollBehavior {
  const _ClampingScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}

class FileEditorViewState extends State<FileEditorView> {
  /// Used to reach the inner [EditableText] (its own vertical scroll
  /// controller and [RenderEditable]) so the editor can scroll the caret
  /// into view after programmatic text changes — see
  /// [_revealCaretIfNeeded].
  final GlobalKey _codeFieldKey = GlobalKey();

  late final CodeController _controller;
  late String _originalContent;

  /// The last full text the controller held at listener time. Enter, Tab,
  /// autocomplete, undo/redo — flutter_code_editor's editing keys — all
  /// change the text; selection-only movements (arrow keys, drag) do not,
  /// and must not trigger the caret reveal.
  late String _lastRevealText;

  DateTime? _mtime;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = CodeController(
      text: widget.initialContent,
      language: codeEditorLanguageForPath(widget.path),
    );
    _originalContent = widget.initialContent;
    _lastRevealText = widget.initialContent;
    _mtime = widget.initialMtime;
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final text = _controller.fullText;
    final textChanged = text != _lastRevealText;
    _lastRevealText = text;

    final isDirty = text != _originalContent;
    if (widget.dirty.value != isDirty) widget.dirty.value = isDirty;

    // flutter_code_editor routes Enter/Tab/etc. through programmatic
    // CodeController writes, and EditableText deliberately does NOT scroll
    // the caret into view for programmatic text changes (it only reveals
    // for platform-driven updateEditingValue). So Enter at the end of a
    // line flush against the bottom edge left the caret off-screen with the
    // viewport pinned. Scroll it into view ourselves.
    if (textChanged) _revealCaretAfterChange();
  }

  /// Scrolls the caret back into view after the new text has been laid out.
  /// Only runs when the caret has actually left the viewport — for a caret
  /// still in view it is a no-op, so it never fights a correct native reveal
  /// or a drag selection.
  ///
  /// The actual jump is deferred to the NEXT frame's post-frame phase
  /// (post-frame callbacks appended while the list is being drained run next
  /// frame, which we then schedule explicitly). That lands it after any
  /// native reveal EditableText may also have scheduled for this change,
  /// which misbehaves in the editor's internally-scrollable `expands: true`
  /// configuration and can fling the viewport to its end.
  void _revealCaretAfterChange() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _revealCaretTargets() == null) return;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        final targets = _revealCaretTargets();
        if (targets == null) return;
        if (targets.$1 != null) {
          _editableState?.widget.scrollController?.jumpTo(targets.$1!);
        }
        if (targets.$2 != null) {
          _horizontalScrollPosition?.jumpTo(targets.$2!);
        }
      });
      SchedulerBinding.instance.scheduleFrame();
    });
  }

  /// The vertical and horizontal offsets that bring the caret fully into
  /// view, as a `(v, h)` record, or `null` when the caret is already in view
  /// on both axes. Call only after layout.
  ///
  /// [RenderEditable.getLocalRectForCaret] returns the caret rect relative
  /// to the field: its vertical range already has the field's vertical scroll
  /// baked in (so a caret below the fold has `bottom > viewportDimension`),
  /// but its horizontal range is in field coordinates, which the outer
  /// horizontal scroll view shows as `[hPixels, hPixels + hViewport]`.
  (double?, double?)? _revealCaretTargets() {
    final editable = _editableState;
    if (editable == null) return null;
    final scroll = editable.widget.scrollController;
    if (scroll == null || !scroll.hasClients) return null;
    final selection = _controller.selection;
    if (!selection.isValid) return null;

    final caret = editable.renderEditable.getLocalRectForCaret(
      selection.extent,
    );

    double? vTarget;
    final position = scroll.position;
    final vPixels = position.pixels;
    var v = vPixels;
    if (caret.bottom > position.viewportDimension) {
      // Caret below the fold — bring its bottom edge up to the bottom edge.
      v = vPixels + (caret.bottom - position.viewportDimension);
    } else if (caret.top < 0) {
      // Caret above the fold — bring its top edge back into view.
      v = vPixels + caret.top;
    }
    v = v.clamp(0.0, position.maxScrollExtent);
    if ((v - vPixels).abs() > 0.1) vTarget = v;

    double? hTarget;
    final h = _horizontalScrollPosition;
    if (h != null) {
      final hPixels = h.pixels;
      var ht = hPixels;
      if (caret.right > hPixels + h.viewportDimension) {
        // Caret past the right edge — bring its right edge to the right edge.
        ht = caret.right - h.viewportDimension;
      } else if (caret.left < hPixels) {
        // Caret off the left edge (e.g. Enter moved it to column 0 of a line
        // while the view was scrolled to a long line's end) — bring its left
        // edge back to the left edge.
        ht = caret.left;
      }
      ht = ht.clamp(0.0, h.maxScrollExtent);
      if ((ht - hPixels).abs() > 0.1) hTarget = ht;
    }

    if (vTarget == null && hTarget == null) return null;
    return (vTarget, hTarget);
  }

  /// The [EditableText] inside the [CodeField] — the render object and
  /// scroll controller that own the caret.
  EditableTextState? get _editableState {
    final context = _codeFieldKey.currentContext;
    if (context == null) return null;
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget is EditableText) {
        found = (element as StatefulElement).state as EditableTextState;
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  /// The scroll position of flutter_code_editor's outer horizontal scroll
  /// view, which carries the horizontal axis of the field (the field's own
  /// scroll controller only scrolls vertically). Walks up from the field to
  /// find it; returns `null` when there is nothing to scroll horizontally
  /// (no horizontal scroll extent).
  ScrollPosition? get _horizontalScrollPosition {
    final editable = _editableState;
    if (editable == null) return null;
    ScrollPosition? found;
    editable.context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Scrollable && widget.axis != Axis.vertical) {
        found =
            ((element as StatefulElement).state as ScrollableState).position;
        return false;
      }
      return true;
    });
    return found;
  }

  SftpFileSystemAdapter get _adapter =>
      SftpFileSystemAdapter(sftp: widget.sftp, label: widget.label);

  /// Saves the current buffer. Returns `true` when it's safe for the
  /// caller to close this tab afterward (save succeeded, OR the user
  /// resolved an mtime conflict by choosing to reload and discard local
  /// changes) — `false` when the tab should stay open (save failed, or
  /// the conflict dialog didn't resolve to either outcome).
  Future<bool> save() async {
    if (_saving) return false;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await _adapter.commit(
        widget.path,
        _controller.fullText,
        expectedMtime: _mtime,
      );
      if (!mounted) return true;
      setState(() {
        _originalContent = _controller.fullText;
        _mtime = result.mtime;
        _saving = false;
      });
      widget.dirty.value = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return true;
    } on FileWriteException catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      if (e.kind == FileWriteErrorKind.mtimeMismatch) {
        return _resolveConflict();
      }
      setState(() => _error = _humanSaveError(e));
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _error = 'Save failed: $e';
      });
      return false;
    }
  }

  Future<bool> _resolveConflict() async {
    final colors = AppColors.maybeOf(context);
    final choice = await showDialog<_ConflictChoice>(
      context: context,
      builder: (ctx) => Theme(
        data: Theme.of(
          context,
        ).copyWith(extensions: colors != null ? {colors} : null),
        child: const _ConflictDialog(),
      ),
    );
    if (!mounted) return false;
    if (choice == _ConflictChoice.overwrite) {
      try {
        final result = await _adapter.commit(widget.path, _controller.fullText);
        if (!mounted) return true;
        setState(() {
          _originalContent = _controller.fullText;
          _mtime = result.mtime;
        });
        widget.dirty.value = false;
        return true;
      } catch (e) {
        if (!mounted) return false;
        setState(() => _error = 'Save failed: $e');
        return false;
      }
    }
    if (choice == _ConflictChoice.reload) {
      await _reload();
      return true;
    }
    return false;
  }

  Future<void> _reload() async {
    try {
      final content = await _adapter.readContent(widget.path);
      final preview = await _adapter.preview(widget.path);
      if (!mounted) return;
      setState(() {
        // fullText (not text) — a plain `.text =` assignment would
        // bypass CodeController's folding-aware Code model and could
        // leave stale fold-block bookkeeping pointing at line numbers
        // that no longer make sense after this full-content replace.
        _controller.fullText = content;
        _originalContent = content;
        _mtime = preview.mtime;
        _error = null;
      });
      widget.dirty.value = false;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Reload failed: $e');
    }
  }

  String _humanSaveError(FileWriteException e) => switch (e.kind) {
    FileWriteErrorKind.permission => 'Permission denied writing to this file.',
    FileWriteErrorKind.notSupported =>
      'The connection to this file is no longer available.',
    FileWriteErrorKind.tooLarge => 'File is too large to save from the editor.',
    FileWriteErrorKind.parentMissing =>
      'The containing folder no longer exists.',
    FileWriteErrorKind.invalidPath => 'Invalid path.',
    FileWriteErrorKind.io => 'Save failed: ${e.message}',
    FileWriteErrorKind.mtimeMismatch =>
      'Save failed: ${e.message}', // unreachable — handled by _resolveConflict above
  };

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final fg = colors?.foreground ?? _kFgActive;
    final fgDim = colors?.foregroundDim ?? _kFgDim;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
          save();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          save();
        },
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: _kBg,
          child: Column(
            children: [
              _buildToolbar(fg, fgDim),
              if (_error != null) _buildErrorBar(),
              Expanded(
                child: CodeTheme(
                  data: CodeThemeData(styles: atomOneDarkTheme),
                  child: ScrollConfiguration(
                    // macOS's ScrollBehavior defaults every scrollable to
                    // BouncingScrollPhysics — the rubber-band overscroll
                    // where scrolling past the end pulls the content back
                    // with a spring. Clamp instead: the editor stops dead
                    // at its edges, on both the outer horizontal axis and
                    // the field's own vertical axis.
                    behavior: const _ClampingScrollBehavior(),
                    child: CodeField(
                      key: _codeFieldKey,
                      controller: _controller,
                      // Let the editor own its own vertical scrolling
                      // instead of wrapping it in a SingleChildScrollView.
                      // With expands:false + an outer scroll view the inner
                      // TextField grows to full content height, so its
                      // scroll controller has no extent and drag-selecting
                      // across lines can't auto-scroll the viewport to
                      // follow the selection — the window only moves in
                      // fixed jumps. expands:true makes the TextField
                      // internally scrollable, restoring the auto-scroll
                      // behavior.
                      expands: true,
                      // Keep the code area's background matched to our
                      // chrome: CodeField otherwise paints its OWN
                      // background from the highlight theme's root style
                      // (Atom One Dark's #282c34) instead of _kBg
                      // (#1E1E1E), showing up as a hard seam against the
                      // toolbar. (The rubber-band overscroll that used to
                      // reveal this under the viewport edge is gone — the
                      // editor now clamps, see _ClampingScrollBehavior.)
                      background: _kBg,
                      textStyle: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 13,
                        height: 1.4,
                      ),
                      // Gutter off entirely: flutter_code_editor 0.3.5's
                      // gutter mis-renders line numbers in this app
                      // (values repeat/skip, not just visual misalignment)
                      // — a display bug, not a data-loss risk (the
                      // .fullText save path is unaffected). Hiding just
                      // the number column left the gutter's width
                      // uncomputed (CodeField only sizes the gutter
                      // Container when showLineNumbers is true), which
                      // showed up as leftover blank space — GutterStyle
                      // .none collapses the whole gutter to zero width,
                      // which is the package's own documented way to
                      // hide it (rather than setting every show* flag
                      // false individually).
                      gutterStyle: GutterStyle.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(Color fg, Color fgDim) {
    return Container(
      height: 40,
      color: _kToolbar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(Icons.edit_note, size: 16, color: fgDim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.path,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: widget.dirty,
            builder: (_, dirty, _) => Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: dirty ? _kAccent : Colors.transparent,
                shape: BoxShape.circle,
              ),
            ),
          ),
          TextButton(
            onPressed: _reload,
            child: Text('Reload', style: TextStyle(color: fgDim, fontSize: 12)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: _saving ? null : () => save(),
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'Save',
                    style: TextStyle(color: _kAccent, fontSize: 12),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBar() {
    return Container(
      width: double.infinity,
      color: _kDanger.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        _error!,
        style: const TextStyle(color: _kDanger, fontSize: 12),
      ),
    );
  }
}

class _ConflictDialog extends StatelessWidget {
  const _ConflictDialog();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final fill = colors?.popup ?? FrostedGlassStyle.menuFillFrosted;
    final fg = colors?.foreground ?? _kFgActive;
    final fgDim = colors?.foregroundDim ?? _kFgDim;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 380,
        child: PopupSurface(
          color: fill,
          backdropBlur: 20,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'File changed',
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'This file was modified elsewhere while you were editing it.',
                  style: TextStyle(color: fgDim, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, _ConflictChoice.reload),
                      child: Text(
                        'Reload (discard my changes)',
                        style: TextStyle(color: fgDim),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, _ConflictChoice.overwrite),
                      child: const Text(
                        'Overwrite',
                        style: TextStyle(color: _kDanger),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
