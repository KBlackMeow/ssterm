import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
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

class FileEditorViewState extends State<FileEditorView> {
  late final CodeController _controller;
  late String _originalContent;
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
    _mtime = widget.initialMtime;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final isDirty = _controller.fullText != _originalContent;
    if (widget.dirty.value != isDirty) widget.dirty.value = isDirty;
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
        data: Theme.of(context)
            .copyWith(extensions: colors != null ? {colors} : null),
        child: const _ConflictDialog(),
      ),
    );
    if (!mounted) return false;
    if (choice == _ConflictChoice.overwrite) {
      try {
        final result =
            await _adapter.commit(widget.path, _controller.fullText);
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
    FileWriteErrorKind.tooLarge =>
      'File is too large to save from the editor.',
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
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: CodeTheme(
                    data: CodeThemeData(styles: atomOneDarkTheme),
                    child: SingleChildScrollView(
                      child: CodeField(
                        controller: _controller,
                        expands: false,
                        textStyle: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
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
                : const Text('Save',
                    style: TextStyle(color: _kAccent, fontSize: 12)),
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
      child: Text(_error!, style: const TextStyle(color: _kDanger, fontSize: 12)),
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
