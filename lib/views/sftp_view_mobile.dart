part of 'sftp_view.dart';

// ────────────────────────────────────────────────────────────────────────────
// Compact list row — iOS 26 style
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
    final isDir  = entry.attr.isDirectory;
    final isLink = entry.attr.isSymbolicLink;

    final colors  = AppColors.maybeOf(context);
    final fg      = colors?.foreground    ?? const Color(0xFFD4D4D4);
    final fgDim   = colors?.foregroundDim ?? const Color(0xFF8E8E8E);

    final iconColor = isDir
        ? const Color(0xFFFFD166)
        : isLink ? const Color(0xFF4EC9B0) : fgDim;

    final nameColor = isDir
        ? fg
        : isLink ? const Color(0xFF4EC9B0) : fg.withValues(alpha: 0.70);

    final metaColor = fgDim.withValues(alpha: 0.75);
    final arrowColor = fg.withValues(alpha: 0.15);

    final sizeText = isDir ? '' : _sftpFmtSize(entry.attr.size ?? 0);
    final dateText = _sftpFmtDate(entry.attr.modifyTime);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      overlayColor: WidgetStateProperty.all(const Color(0x0AFFFFFF)),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Icon(
                  isDir ? Icons.folder_rounded
                      : isLink ? Icons.link_rounded
                      : _fileIconForName(entry.filename),
                  size: 26,
                  color: iconColor,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  entry.filename,
                  style: TextStyle(color: nameColor, fontSize: 16, fontFamily: 'JetBrainsMono'),
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
                    Text(sizeText,
                        style: TextStyle(color: metaColor, fontSize: 13, fontFamily: 'JetBrainsMono')),
                  Text(dateText,
                      style: TextStyle(color: metaColor, fontSize: 13, fontFamily: 'JetBrainsMono')),
                ],
              ),
              if (isDir)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.chevron_right_rounded, size: 18, color: arrowColor),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.more_vert_rounded, size: 17,
                      color: arrowColor.withValues(alpha: arrowColor.a * 0.7)),
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
      'xml' || 'ini' || 'conf'                   => Icons.data_object_rounded,
      'md' || 'txt' || 'log' || 'rst'            => Icons.description_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' ||
      'svg' || 'webp' || 'ico'                   => Icons.image_outlined,
      'zip' || 'tar' || 'gz' || 'bz2' ||
      'xz' || '7z' || 'rar'                      => Icons.archive_outlined,
      'sh' || 'bash' || 'zsh' || 'fish'          => Icons.terminal_rounded,
      _                                          => Icons.insert_drive_file_outlined,
    };
  }

}

// ────────────────────────────────────────────────────────────────────────────
// Mobile action sheet — iOS 26 Liquid Glass style
// ────────────────────────────────────────────────────────────────────────────

class _MobileActionSheet extends StatelessWidget {
  const _MobileActionSheet({
    required this.entry,
    required this.canDownload,
    this.frostedGlass = false,
    this.chromeBackground = const Color(0xFF111113),
  });

  final SftpName entry;
  final bool canDownload;
  final bool frostedGlass;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    final isDir     = entry.attr.isDirectory;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    const radius    = BorderRadius.vertical(top: Radius.circular(20));

    final colors    = AppColors.maybeOf(context);
    final fg        = colors?.foreground    ?? _kFgActive;
    final fgDim     = colors?.foregroundDim ?? _kFgMuted;
    final sheetBg   = colors?.popup ?? (frostedGlass ? FrostedGlassStyle.menuFillFrosted : const Color(0xFF111113));
    final topBorder = fg.withValues(alpha: 0.16);
    final divColor  = fgDim.withValues(alpha: 0.18);
    final iconBg    = fgDim.withValues(alpha: 0.15);

    Widget sheet = Container(
      decoration: BoxDecoration(
        color: sheetBg,
        borderRadius: radius,
        border: Border(top: BorderSide(color: topBorder, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

          // File header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isDir
                        ? const Color(0xFFFFD166).withValues(alpha: 0.12)
                        : iconBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
                    size: 20,
                    color: isDir ? const Color(0xFFFFD166) : fgDim,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.filename,
                        style: TextStyle(
                          color: fg,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'JetBrainsMono',
                          letterSpacing: -0.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isDir ? 'Folder' : _sftpFmtSize(entry.attr.size ?? 0),
                        style: TextStyle(color: fgDim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Divider(height: 1, color: divColor),
          const SizedBox(height: 4),

          if (isDir)
            _SheetItem(icon: Icons.folder_open_rounded, label: 'Open',
                onTap: () => Navigator.pop(context, 'navigate')),
          if (canDownload)
            _SheetItem(
              icon: Icons.download_rounded,
              label: Platform.isIOS ? 'Save to Files' : 'Download',
              onTap: () => Navigator.pop(context, 'download'),
            ),
          _SheetItem(icon: Icons.drive_file_rename_outline_rounded, label: 'Rename',
              onTap: () => Navigator.pop(context, 'rename')),
          const SizedBox(height: 4),
          Divider(height: 1, color: divColor),
          _SheetItem(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            labelColor: const Color(0xFFFF6E67),
            iconColor:  const Color(0xFFFF6E67),
            onTap: () => Navigator.pop(context, 'delete'),
          ),

          SizedBox(height: bottomPad + 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (frostedGlass) {
      sheet = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: sheet,
        ),
      );
    }

    return sheet;
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Shared sheet widgets
// ────────────────────────────────────────────────────────────────────────────

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    final handleColor = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgMuted).withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: handleColor,
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
    this.iconColor,
    this.labelColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final colors      = AppColors.maybeOf(context);
    final effectiveIcon  = iconColor  ?? colors?.foregroundDim ?? _kFgMuted;
    final effectiveLabel = labelColor ?? colors?.foreground    ?? _kFgActive;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        overlayColor: WidgetStateProperty.all(const Color(0x0AFFFFFF)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              SizedBox(width: 28, child: Icon(icon, size: 20, color: effectiveIcon)),
              const SizedBox(width: 14),
              Text(label, style: TextStyle(color: effectiveLabel, fontSize: 16)),
            ],
          ),
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
    final colors   = AppColors.maybeOf(context);
    final fg       = colors?.foreground    ?? Colors.white;
    final fgDim    = colors?.foregroundDim ?? _kFgMuted;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 50,
        child: Icon(
          icon,
          size: 20,
          color: disabled ? fg.withValues(alpha: 0.12) : fgDim.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}
