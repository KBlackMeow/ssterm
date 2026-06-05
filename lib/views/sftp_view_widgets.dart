part of 'sftp_view.dart';

// ────────────────────────────────────────────────────────────────────────────
// Desktop toolbar button
// ────────────────────────────────────────────────────────────────────────────

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
    final fgNormal = AppColors.maybeOf(context)?.foregroundDim ?? _kFgMuted;
    final fgHover  = AppColors.maybeOf(context)?.foreground    ?? const Color(0xFFC7C7C7);
    final fgDisabled = AppColors.maybeOf(context)?.foreground.withValues(alpha: 0.2) ?? _kFgDisabled;
    final color = disabled
        ? fgDisabled
        : widget.danger
            ? const Color(0xFFFF6E67)
            : _hover
                ? fgHover
                : fgNormal;

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

// ────────────────────────────────────────────────────────────────────────────
// Dialogs
// ────────────────────────────────────────────────────────────────────────────

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
    final colors   = AppColors.maybeOf(context);
    final fill     = colors?.popup  ?? FrostedGlassStyle.menuFillFrosted;
    final fg       = colors?.foreground    ?? const Color(0xFFC7C7C7);
    final fgDim    = colors?.foregroundDim ?? const Color(0xFF8E8E8E);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 360,
        child: PopupSurface(
          color: fill,
          backdropBlur: 20,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title,
                    style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(body, style: TextStyle(color: fgDim, fontSize: 13, height: 1.4)),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('Cancel', style: TextStyle(color: fgDim)),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(confirm,
                          style: TextStyle(color: danger ? const Color(0xFFFF6E67) : _kAccent)),
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
    final colors  = AppColors.maybeOf(context);
    final fill    = colors?.popup          ?? FrostedGlassStyle.menuFillFrosted;
    final fg      = colors?.foreground     ?? const Color(0xFFC7C7C7);
    final fgDim   = colors?.foregroundDim  ?? const Color(0xFF8E8E8E);
    final fieldBg = fg.withValues(alpha: 0.07);
    final fieldBd = fg.withValues(alpha: 0.15);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: SizedBox(
        width: 360,
        child: PopupSurface(
          color: fill,
          backdropBlur: 20,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title,
                    style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: TextStyle(color: fg, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: fieldBg,
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: fieldBd)),
                    focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: _kAccent)),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  ),
                  onSubmitted: (v) => Navigator.pop(context, v),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('Cancel', style: TextStyle(color: fgDim)),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(context, ctrl.text),
                      child: Text(confirm, style: const TextStyle(color: _kAccent)),
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
