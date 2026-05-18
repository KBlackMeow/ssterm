import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../models/transfer_task.dart';
import '../services/file_picker_service.dart';
import 'ssh_session_view.dart' show SftpPanelPosition;

/// Join a remote directory path with a file/dir name.
String sftpJoin(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';

/// Return the parent of a remote path, or '/' if already at root.
String sftpParent(String path) {
  if (path == '/') return '/';
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

/// Sort rank for SFTP entries: 0 = directory, 1 = symlink, 2 = regular file.
int sftpEntryRank({required bool isDirectory, required bool isSymbolicLink}) {
  if (isDirectory) return 0;
  if (isSymbolicLink) return 1;
  return 2;
}

const _kSizeColWidth = 44.0;
const _kDateColWidth = 72.0;
const _kMetaFontSize = 9.0;

class SftpView extends StatefulWidget {
  const SftpView({
    super.key,
    required this.sftp,
    required this.host,
    required this.transferManager,
    this.remotePath,
    this.panelPosition,
    this.onPanelPositionChanged,
    this.onClose,
  });

  final SftpClient sftp;
  final String host;
  final TransferManager transferManager;

  /// When set, the panel follows this path (e.g. synced from the SSH shell cwd).
  final ValueNotifier<String>? remotePath;

  final SftpPanelPosition? panelPosition;
  final ValueChanged<SftpPanelPosition>? onPanelPositionChanged;
  final VoidCallback? onClose;

  @override
  State<SftpView> createState() => _SftpViewState();
}

class _SftpViewState extends State<SftpView> {
  String _path = '/';
  List<SftpName> _entries = [];
  bool _loading = true;
  String? _error;
  SftpName? _selected;
  String? _status;
  bool _isDragOver = false;

  @override
  void initState() {
    super.initState();
    final sync = widget.remotePath;
    if (sync != null) {
      sync.addListener(_onRemotePathChanged);
      if (sync.value.isNotEmpty) {
        _listDir(sync.value);
      } else {
        _loading = true;
      }
    } else {
      _listDir('/');
    }
  }

  @override
  void dispose() {
    widget.remotePath?.removeListener(_onRemotePathChanged);
    super.dispose();
  }

  void _onRemotePathChanged() {
    final p = widget.remotePath?.value;
    if (p == null || p.isEmpty || p == _path) return;
    _listDir(p);
  }

  Future<void> _listDir(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
    });
    try {
      final raw = await widget.sftp.listdir(path);
      raw.sort((a, b) {
        final r = sftpEntryRank(
              isDirectory: a.attr.isDirectory,
              isSymbolicLink: a.attr.isSymbolicLink,
            ).compareTo(sftpEntryRank(
              isDirectory: b.attr.isDirectory,
              isSymbolicLink: b.attr.isSymbolicLink,
            ));
        return r != 0 ? r : a.filename.compareTo(b.filename);
      });
      if (mounted) {
        setState(() {
          _path = path;
          _entries = raw.where((e) => e.filename != '.').toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _download(SftpName entry) async {
    final home = Platform.environment['HOME'] ?? '';
    final dest = '$home/Downloads/${entry.filename}';
    try {
      await widget.transferManager.startDownload(
        sftp: widget.sftp,
        remotePath: sftpJoin(_path, entry.filename),
        localPath: dest,
      );
    } catch (e) {
      if (mounted) setState(() => _status = 'Download error: $e');
    }
  }

  Future<void> _upload() async {
    final localPath = await FilePickerService.pickFile();
    if (localPath == null) return;
    await _uploadPath(localPath);
  }

  Future<void> _uploadPath(String localPath) async {
    final fileName = localPath.split(Platform.pathSeparator).last;
    final uploadDir = _path;
    try {
      final task = await widget.transferManager.startUpload(
        sftp: widget.sftp,
        localPath: localPath,
        remotePath: sftpJoin(uploadDir, fileName),
      );
      void listener() {
        if (!task.isActive) {
          task.removeListener(listener);
          if (mounted && task.status == TransferStatus.done && _path == uploadDir) {
            _listDir(_path);
          }
        }
      }
      task.addListener(listener);
    } catch (e) {
      if (mounted) setState(() => _status = 'Upload error: $e');
    }
  }

  Future<void> _delete(SftpName entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ConfirmDialog(
        title: 'Delete',
        body: 'Delete "${entry.filename}"?',
        confirm: 'Delete',
        danger: true,
      ),
    );
    if (ok != true) return;

    try {
      final p = sftpJoin(_path, entry.filename);
      if (entry.attr.isDirectory) {
        await widget.sftp.rmdir(p);
      } else {
        await widget.sftp.remove(p);
      }
      _listDir(_path);
    } catch (e) {
      if (mounted) setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _rename(SshFtpEntry entry) async {
    final ctrl = TextEditingController(text: entry.name.filename);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _InputDialog(title: 'Rename', ctrl: ctrl, confirm: 'Rename'),
    );
    if (name == null || name.isEmpty || name == entry.name.filename) return;

    try {
      await widget.sftp.rename(
        sftpJoin(_path, entry.name.filename),
        sftpJoin(_path, name),
      );
      _listDir(_path);
    } catch (e) {
      if (mounted) setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _mkdir() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _InputDialog(title: 'New Folder', ctrl: ctrl, confirm: 'Create'),
    );
    if (name == null || name.isEmpty) return;

    try {
      await widget.sftp.mkdir(sftpJoin(_path, name));
      _listDir(_path);
    } catch (e) {
      if (mounted) setState(() => _status = 'Error: $e');
    }
  }

  /// Handle a tap on an entry. Directories and symlinks-to-dirs navigate;
  /// everything else toggles selection.
  Future<void> _navigateEntry(SftpName e) async {
    if (e.attr.isDirectory) {
      await _listDir(e.filename == '..'
          ? sftpParent(_path)
          : sftpJoin(_path, e.filename));
      return;
    }
    if (e.attr.isSymbolicLink) {
      try {
        final targetPath = sftpJoin(_path, e.filename);
        final stat = await widget.sftp.stat(targetPath);
        if (stat.isDirectory) {
          await _listDir(targetPath);
          return;
        }
      } catch (_) {}
    }
    final isSel = _selected?.filename == e.filename;
    setState(() => _selected = isSel ? null : e);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1C1C1C),
      child: Column(
        children: [
          _buildToolbar(),
          _buildColumnHeader(),
          Expanded(
            child: DropTarget(
              onDragEntered: (_) => setState(() => _isDragOver = true),
              onDragExited: (_) => setState(() => _isDragOver = false),
              onDragDone: (detail) {
                setState(() => _isDragOver = false);
                for (final file in detail.files) {
                  _uploadPath(file.path);
                }
              },
              child: Stack(
                children: [
                  _buildBody(),
                  if (_isDragOver)
                    Container(
                      color: const Color(0xFF2472C8).withAlpha(40),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2472C8).withAlpha(200),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.upload, color: Colors.white, size: 16),
                            SizedBox(width: 8),
                            Text(
                              'Drop to upload',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_status != null) _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final canDown = _selected != null && !_selected!.attr.isDirectory;
    final canDel = _selected != null;
    return Container(
      height: 34,
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          _ToolBtn(
            icon: Icons.arrow_upward,
            tooltip: 'Parent',
            onTap: _path == '/' ? null : () => _listDir(sftpParent(_path)),
          ),
          _ToolBtn(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onTap: () => _listDir(_path),
          ),
          const SizedBox(width: 4),
          const SizedBox(
            height: 16,
            child: VerticalDivider(color: Color(0xFF3A3A3A), width: 1),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _path,
              style: const TextStyle(
                color: Color(0xFF8E8E8E),
                fontSize: 11,
                fontFamily: 'Monaco',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          const SizedBox(
            height: 16,
            child: VerticalDivider(color: Color(0xFF3A3A3A), width: 1),
          ),
          const SizedBox(width: 4),
          if (widget.panelPosition != null &&
              widget.onPanelPositionChanged != null)
            _ToolBtn(
              icon: widget.panelPosition == SftpPanelPosition.right
                  ? Icons.view_agenda_outlined
                  : Icons.view_sidebar_outlined,
              tooltip: widget.panelPosition == SftpPanelPosition.right
                  ? 'Move to bottom'
                  : 'Move to right',
              onTap: () => widget.onPanelPositionChanged!(
                widget.panelPosition == SftpPanelPosition.right
                    ? SftpPanelPosition.bottom
                    : SftpPanelPosition.right,
              ),
            ),
          _ToolBtn(
            icon: Icons.upload,
            tooltip: 'Upload',
            onTap: _upload,
          ),
          _ToolBtn(
            icon: Icons.download,
            tooltip: 'Download',
            onTap: canDown ? () => _download(_selected!) : null,
          ),
          _ToolBtn(
            icon: Icons.create_new_folder_outlined,
            tooltip: 'New Folder',
            onTap: _mkdir,
          ),
          _ToolBtn(
            icon: Icons.delete_outline,
            tooltip: 'Delete',
            onTap: canDel ? () => _delete(_selected!) : null,
            danger: canDel,
          ),
          if (widget.onClose != null) ...[
            const SizedBox(width: 4),
            const SizedBox(
              height: 16,
              child: VerticalDivider(color: Color(0xFF3A3A3A), width: 1),
            ),
            _ToolBtn(
              icon: Icons.close,
              tooltip: 'Hide SFTP',
              onTap: widget.onClose,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildColumnHeader() {
    return Container(
      height: 24,
      color: const Color(0xFF222222),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const SizedBox(width: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Name',
              style: TextStyle(
                color: Color(0xFF686868),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          const SizedBox(
            width: _kSizeColWidth,
            child: Text(
              'Size',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Color(0xFF686868),
                fontSize: _kMetaFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 4),
          const SizedBox(
            width: _kDateColWidth,
            child: Text(
              'Modified',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Color(0xFF686868),
                fontSize: _kMetaFontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF2472C8),
          strokeWidth: 2,
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: Color(0xFFFF6E67), fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (_, i) {
        final e = _entries[i];
        final isDir = e.attr.isDirectory;
        final isLink = e.attr.isSymbolicLink;
        final isSel = _selected?.filename == e.filename;
        return GestureDetector(
          onSecondaryTapDown: (d) => _showContextMenu(e, d.globalPosition),
          child: InkWell(
            onTap: () => _navigateEntry(e),
            child: Container(
              height: 24,
              color: isSel ? const Color(0xFF2472C8).withAlpha(70) : null,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(
                    isDir
                        ? Icons.folder
                        : isLink
                            ? Icons.link
                            : _fileIcon(e.filename),
                    size: 13,
                    color: isDir
                        ? const Color(0xFFFFD166)
                        : isLink
                            ? const Color(0xFF4EC9B0)
                            : const Color(0xFF686868),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Tooltip(
                      message: e.filename,
                      waitDuration: const Duration(milliseconds: 400),
                      child: Text(
                        e.filename,
                        style: TextStyle(
                          color: isDir
                              ? const Color(0xFFC7C7C7)
                              : isLink
                                  ? const Color(0xFF4EC9B0)
                                  : const Color(0xFFAAAAAA),
                          fontSize: 12,
                          fontFamily: 'Monaco',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: _kSizeColWidth,
                    child: Text(
                      isDir ? '' : _fmtSize(e.attr.size ?? 0),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF686868),
                        fontSize: _kMetaFontSize,
                        fontFamily: 'Monaco',
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: _kDateColWidth,
                    child: Text(
                      _fmtDate(e.attr.modifyTime),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF686868),
                        fontSize: _kMetaFontSize,
                        fontFamily: 'Monaco',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showContextMenu(SftpName e, Offset globalPosition) async {
    final isDir = e.attr.isDirectory;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      globalPosition & Size.zero,
      Offset.zero & overlay.size,
    );

    await showMenu(
      context: context,
      color: const Color(0xFF2B2B2B),
      position: position,
      items: [
        if (!isDir)
          PopupMenuItem(
            onTap: () => _download(e),
            child: const Text(
              'Download',
              style: TextStyle(color: Color(0xFFC7C7C7), fontSize: 13),
            ),
          ),
        PopupMenuItem(
          onTap: () => _rename(SshFtpEntry(e)),
          child: const Text(
            'Rename',
            style: TextStyle(color: Color(0xFFC7C7C7), fontSize: 13),
          ),
        ),
        PopupMenuItem(
          onTap: () => _delete(e),
          child: const Text(
            'Delete',
            style: TextStyle(color: Color(0xFFFF6E67), fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    return Container(
      height: 22,
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _status ?? '',
              style: const TextStyle(color: Color(0xFF8E8E8E), fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${_entries.length} items',
            style: const TextStyle(color: Color(0xFF686868), fontSize: 11),
          ),
        ],
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'dart' ||
      'py' ||
      'js' ||
      'ts' ||
      'go' ||
      'rs' ||
      'c' ||
      'cpp' ||
      'java' ||
      'swift' ||
      'kt' => Icons.code,
      'json' ||
      'yaml' ||
      'yml' ||
      'toml' ||
      'xml' ||
      'ini' ||
      'conf' => Icons.data_object,
      'md' || 'txt' || 'log' || 'rst' => Icons.description_outlined,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'svg' ||
      'webp' ||
      'ico' => Icons.image_outlined,
      'zip' ||
      'tar' ||
      'gz' ||
      'bz2' ||
      'xz' ||
      '7z' ||
      'rar' => Icons.archive_outlined,
      'sh' || 'bash' || 'zsh' || 'fish' => Icons.terminal,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} K';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} M';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} G';
  }

  String _fmtDate(int? ts) {
    if (ts == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final today =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (today) return hm;
    return '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} $hm';
  }
}

// Wrapper to pass SftpName into rename dialog
class SshFtpEntry {
  final SftpName name;
  SshFtpEntry(this.name);
}

class _ToolBtn extends StatefulWidget {
  const _ToolBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool danger;

  @override
  State<_ToolBtn> createState() => _ToolBtnState();
}

class _ToolBtnState extends State<_ToolBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    final color = disabled
        ? const Color(0xFF3A3A3A)
        : widget.danger
        ? const Color(0xFFFF6E67)
        : _hover
        ? const Color(0xFFC7C7C7)
        : const Color(0xFF8E8E8E);

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 14, color: color),
          ),
        ),
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.body,
    required this.confirm,
    this.danger = false,
  });

  final String title;
  final String body;
  final String confirm;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2B2B),
      title: Text(
        title,
        style: const TextStyle(color: Color(0xFFC7C7C7), fontSize: 14),
      ),
      content: Text(
        body,
        style: const TextStyle(color: Color(0xFF8E8E8E), fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Color(0xFF8E8E8E)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            confirm,
            style: TextStyle(
              color: danger ? const Color(0xFFFF6E67) : const Color(0xFF2472C8),
            ),
          ),
        ),
      ],
    );
  }
}

class _InputDialog extends StatelessWidget {
  const _InputDialog({
    required this.title,
    required this.ctrl,
    required this.confirm,
  });

  final String title;
  final TextEditingController ctrl;
  final String confirm;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2B2B),
      title: Text(
        title,
        style: const TextStyle(color: Color(0xFFC7C7C7), fontSize: 14),
      ),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: const TextStyle(color: Color(0xFFC7C7C7), fontSize: 13),
        decoration: const InputDecoration(
          filled: true,
          fillColor: Color(0xFF1C1C1C),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF3A3A3A)),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF2472C8)),
          ),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Color(0xFF8E8E8E)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, ctrl.text),
          child: Text(
            confirm,
            style: const TextStyle(color: Color(0xFF2472C8)),
          ),
        ),
      ],
    );
  }
}
