part of 'sftp_view.dart';

// ────────────────────────────────────────────────────────────────────────────
// Compact list row
// ────────────────────────────────────────────────────────────────────────────

class _CompactRow extends StatelessWidget {
  const _CompactRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  final SftpName entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final isDir = entry.attr.isDirectory;
    final isLink = entry.attr.isSymbolicLink;

    final iconColor = isDir
        ? const Color(0xFFFFD166)
        : isLink
            ? const Color(0xFF4EC9B0)
            : const Color(0xFF8E8E8E);

    final nameColor = isDir
        ? const Color(0xFFD4D4D4)
        : isLink
            ? const Color(0xFF4EC9B0)
            : const Color(0xFFAAAAAA);

    final sizeText = isDir ? '' : _fmtSize(entry.attr.size ?? 0);
    final dateText = _fmtDate(entry.attr.modifyTime);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Icon(
                  isDir
                      ? Icons.folder_rounded
                      : isLink
                          ? Icons.link_rounded
                          : _fileIconForName(entry.filename),
                  size: 22,
                  color: iconColor,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  entry.filename,
                  style: TextStyle(
                    color: nameColor,
                    fontSize: 14,
                    fontFamily: 'JetBrainsMono',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (sizeText.isNotEmpty)
                    Text(
                      sizeText,
                      style: const TextStyle(
                        color: Color(0xFF686868),
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  Text(
                    dateText,
                    style: const TextStyle(
                      color: Color(0xFF686868),
                      fontSize: 11,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ],
              ),
              if (isDir)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: Color(0xFF3A3A3A),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.more_vert_rounded,
                    size: 16,
                    color: Color(0xFF3A3A3A),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _fileIconForName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'dart' || 'py' || 'js' || 'ts' || 'go' || 'rs' ||
      'c' || 'cpp' || 'java' || 'swift' || 'kt' => Icons.code_rounded,
      'json' || 'yaml' || 'yml' || 'toml' ||
      'xml' || 'ini' || 'conf' => Icons.data_object_rounded,
      'md' || 'txt' || 'log' || 'rst' => Icons.description_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' ||
      'svg' || 'webp' || 'ico' => Icons.image_outlined,
      'zip' || 'tar' || 'gz' || 'bz2' ||
      'xz' || '7z' || 'rar' => Icons.archive_outlined,
      'sh' || 'bash' || 'zsh' || 'fish' => Icons.terminal_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} K';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} M';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} G';
  }

  static String _fmtDate(int? ts) {
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

// ────────────────────────────────────────────────────────────────────────────
// Mobile action sheet
// ────────────────────────────────────────────────────────────────────────────

class _MobileActionSheet extends StatelessWidget {
  const _MobileActionSheet({
    required this.entry,
    required this.canDownload,
  });

  final SftpName entry;
  final bool canDownload;

  @override
  Widget build(BuildContext context) {
    final isDir = entry.attr.isDirectory;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Row(
              children: [
                Icon(
                  isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
                  size: 20,
                  color: isDir
                      ? const Color(0xFFFFD166)
                      : const Color(0xFF8E8E8E),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.filename,
                    style: const TextStyle(
                      color: _kFgActive,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'JetBrainsMono',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2A2A)),
          if (isDir)
            _SheetItem(
              icon: Icons.folder_open_rounded,
              label: 'Open',
              onTap: () => Navigator.pop(context, 'navigate'),
            ),
          if (canDownload)
            _SheetItem(
              icon: Icons.download_rounded,
              label: Platform.isIOS ? 'Save to Files' : 'Download',
              onTap: () => Navigator.pop(context, 'download'),
            ),
          _SheetItem(
            icon: Icons.drive_file_rename_outline_rounded,
            label: 'Rename',
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          _SheetItem(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            labelColor: const Color(0xFFFF6E67),
            iconColor: const Color(0xFFFF6E67),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Shared sheet widgets
// ────────────────────────────────────────────────────────────────────────────

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFF3A3A3A),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _SheetItem extends StatelessWidget {
  const _SheetItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor = _kFgMuted,
    this.labelColor = _kFgActive,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color iconColor;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(color: labelColor, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Mobile toolbar button
// ────────────────────────────────────────────────────────────────────────────

class _MobileToolBtn extends StatelessWidget {
  const _MobileToolBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 42,
        height: 50,
        child: Icon(
          icon,
          size: 20,
          color: disabled ? const Color(0xFF3A3A3A) : _kFgMuted,
        ),
      ),
    );
  }
}
