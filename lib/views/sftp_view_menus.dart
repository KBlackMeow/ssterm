part of 'sftp_view.dart';

/// Long-lived menus and breadcrumb sheets used by [SftpViewState].
///
/// Extracted from `sftp_view.dart` to keep the parent file under the
/// project-wide 1000-line cap.  They are implemented as a mixin so they
/// can call back into [SftpViewState]'s private state (`_path`,
/// `_listDir`, `_download`, …) without exporting them.
mixin _SftpMenusMixin on State<SftpView> {
  /// Implemented by [SftpViewState]; the mixin only consumes them.
  String get _path;
  Future<void> _listDir(String path);
  Future<void> _download(SftpName entry);
  Future<void> _rename(SftpName entry);
  Future<void> _delete(SftpName entry);

  /// Bottom-sheet breadcrumb that lets the user jump to any ancestor of
  /// the current path on a phone-sized screen.
  void _showPathBreadcrumb() {
    final segments = _path.split('/').where((s) => s.isNotEmpty).toList();
    showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final colors      = AppColors.maybeOf(context);
        final sheetBg     = colors?.popup ?? FrostedGlassStyle.menuFillFrosted;
        final fg          = colors?.foreground ?? _kFgActive;
        final topBorder   = (colors?.foreground ?? Colors.white).withValues(alpha: 0.16);
        const radius = BorderRadius.vertical(top: Radius.circular(16));
        Widget sheet = Theme(
          data: Theme.of(context).copyWith(extensions: colors != null ? {colors} : null),
          child: Container(
            decoration: BoxDecoration(
              color: sheetBg,
              borderRadius: radius,
              border: Border(top: BorderSide(color: topBorder, width: 0.5)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _SheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    'Go to folder',
                    style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                _SheetItem(
                  icon: Icons.folder_rounded,
                  label: '/',
                  iconColor: const Color(0xFFFFD166),
                  onTap: () { Navigator.pop(ctx); _listDir('/'); },
                ),
                for (var i = 0; i < segments.length; i++)
                  _SheetItem(
                    icon: Icons.folder_rounded,
                    label: '/${segments.sublist(0, i + 1).join('/')}',
                    iconColor: const Color(0xFFFFD166),
                    onTap: () {
                      Navigator.pop(ctx);
                      _listDir('/${segments.sublist(0, i + 1).join('/')}');
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );

        sheet = ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: sheet,
          ),
        );

        return sheet;
      },
    );
  }

  /// Right-click / long-press context menu for a single entry on
  /// desktop (and tablet) form-factors.  See [_showMobileActionSheet]
  /// in `sftp_view_mobile.dart` for the phone-sized equivalent.
  void _showDesktopContextMenu(SftpName e, Offset globalPosition) async {
    final isDir = e.attr.isDirectory;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      globalPosition & Size.zero,
      Offset.zero & overlay.size,
    );

    final action = await showFrostedMenu<String>(
      context: context,
      position: position,
      items: [
        if (!isDir)
          PopupMenuItem(
            value: 'download',
            height: 36,
            child: Builder(
              builder: (ctx) => Text('Download',
                  style: TextStyle(
                    color: AppColors.maybeOf(ctx)?.foreground ?? const Color(0xFFC7C7C7),
                    fontSize: 13,
                  )),
            ),
          ),
        PopupMenuItem(
          value: 'rename',
          height: 36,
          child: Builder(
            builder: (ctx) => Text('Rename',
                style: TextStyle(
                  color: AppColors.maybeOf(ctx)?.foreground ?? const Color(0xFFC7C7C7),
                  fontSize: 13,
                )),
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Text('Delete',
              style: TextStyle(color: Color(0xFFFF6E67), fontSize: 13)),
        ),
      ],
    );

    switch (action) {
      case 'download':
        await _download(e);
      case 'rename':
        await _rename(e);
      case 'delete':
        await _delete(e);
    }
  }
}
