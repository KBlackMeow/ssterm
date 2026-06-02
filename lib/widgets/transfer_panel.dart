import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/transfer_task.dart';
import 'frosted_glass.dart';

const _kDivider = Color(0xFF3A3A3A);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgMuted = Color(0xFF8E8E8E);
const _kBlue = Color(0xFF2472C8);
const _kRed = Color(0xFFFF6E67);
const _kGreen = Color(0xFF4EC9B0);

/// One transfer row: 8+8 padding, title row, 5px gap, status/progress line (~48px content).
const kTransferRowExtent = 64.0;
const kTransferRowSeparator = 1.0;
const kTransferVisibleRows = 5;

/// Viewport for ~5 rows (popup route won't resize after open — scroll inside).
const kTransferListHeight =
    kTransferRowExtent * kTransferVisibleRows +
    kTransferRowSeparator * (kTransferVisibleRows - 1);

/// Header (28) + divider under header (1).
const kTransferMenuChromeHeight = 29.0;

/// Full transfer popup content height (~5 visible rows).
const kTransferMenuHeight = kTransferListHeight + kTransferMenuChromeHeight;

const _kTransferMenuWidth = 280.0;

String _fmtBytes(int b) {
  if (b < 1024) return '${b}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}K';
  if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)}M';
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)}G';
}

String _transferSizeLabel(TransferTask t) =>
    t.total == 0 ? _fmtBytes(t.bytes) : '${_fmtBytes(t.bytes)} / ${_fmtBytes(t.total)}';

OverlayEntry? _activeTransferMenu;

/// Transfer panel as an [Overlay] (not [showMenu]) so live progress updates
/// do not break [PopupMenuRoute] layout / hit-testing over SFTP.
Future<void> showTransferMenu({
  required BuildContext context,
  required RelativeRect position,
  required TransferManager manager,
  bool frostedGlass = true,
}) {
  _activeTransferMenu?.remove();
  _activeTransferMenu = null;

  final overlay = Overlay.of(context, rootOverlay: true);
  final screen = MediaQuery.sizeOf(context);
  final left =
      position.left.clamp(8.0, screen.width - _kTransferMenuWidth - 8);
  final top = position.top
      .clamp(8.0, screen.height - kTransferMenuHeight - 8);

  final completer = Completer<void>();

  void dismiss() {
    if (_activeTransferMenu != null) {
      _activeTransferMenu!.remove();
      _activeTransferMenu = null;
    }
    if (!completer.isCompleted) completer.complete();
  }

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: dismiss,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: _kTransferMenuWidth,
          height: kTransferMenuHeight,
          child: Material(
            type: MaterialType.transparency,
            child: FrostedGlassSurface(
              frosted: frostedGlass,
              blur: false,
              borderRadius: FrostedGlassStyle.menuRadius,
              fillColor: frostedGlass
                  ? FrostedGlassStyle.menuFillFrosted
                  : FrostedGlassStyle.menuFillSolid,
              child: TransferMenuContent(manager: manager),
            ),
          ),
        ),
      ],
    ),
  );

  _activeTransferMenu = entry;
  overlay.insert(entry);
  return completer.future;
}

/// Content widget embedded inside a showMenu popup.
class TransferMenuContent extends StatelessWidget {
  const TransferMenuContent({super.key, required this.manager});

  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: manager,
          builder: (_, _) => _TransferMenuHeader(manager: manager),
        ),
        const Divider(height: 1, thickness: 1, color: _kDivider),
        Expanded(
          child: ListenableBuilder(
            listenable: manager,
            builder: (_, _) => _TransferMenuListBody(manager: manager),
          ),
        ),
      ],
    );
  }
}

class _TransferMenuHeader extends StatelessWidget {
  const _TransferMenuHeader({required this.manager});

  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    final tasks = manager.tasks;
    final active = tasks.where((t) => t.isActive).length;
    final hasDone = tasks.any((t) => !t.isActive);

    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Text(
              'Transfers',
              style: TextStyle(
                color: Color(0xFF6E6E6E),
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
            if (active > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: _kBlue,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$active',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (hasDone)
              GestureDetector(
                onTap: manager.clearDone,
                child: const Text(
                  'Clear done',
                  style: TextStyle(color: _kFgMuted, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TransferMenuListBody extends StatelessWidget {
  const _TransferMenuListBody({required this.manager});

  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    final tasks = manager.tasks;
    if (tasks.isEmpty) {
      return const Center(
        child: Text(
          'No transfers',
          style: TextStyle(color: _kFgMuted, fontSize: 12),
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: tasks.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, thickness: 1, color: _kDivider),
      itemBuilder: (_, i) => SizedBox(
        height: kTransferRowExtent,
        child: _TransferRow(task: tasks[i], manager: manager),
      ),
    );
  }
}

class _TransferRow extends StatefulWidget {
  const _TransferRow({required this.task, required this.manager});

  final TransferTask task;
  final TransferManager manager;

  @override
  State<_TransferRow> createState() => _TransferRowState();
}

class _TransferRowState extends State<_TransferRow> {
  @override
  void initState() {
    super.initState();
    widget.task.addListener(_scheduleRebuild);
  }

  @override
  void didUpdateWidget(_TransferRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      oldWidget.task.removeListener(_scheduleRebuild);
      widget.task.addListener(_scheduleRebuild);
    }
  }

  @override
  void dispose() {
    widget.task.removeListener(_scheduleRebuild);
    super.dispose();
  }

  void _scheduleRebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final manager = widget.manager;
    final isUp = task.type == TransferType.upload;
    final status = task.status;
    final isActive = task.isActive;
    final isPaused = status == TransferStatus.paused;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isUp ? Icons.upload : Icons.download,
                size: 13,
                color: isActive ? _kBlue : _kFgMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  task.name,
                  style:
                      const TextStyle(color: _kFgActive, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _transferSizeLabel(task),
                style: const TextStyle(
                    color: _kFgMuted,
                    fontSize: 10,
                    fontFamily: 'JetBrainsMono'),
              ),
              const SizedBox(width: 4),
              if (isActive) ...[
                _Btn(
                  icon: isPaused ? Icons.play_arrow : Icons.pause,
                  onTap: isPaused ? task.resume : task.pause,
                ),
                _Btn(
                  icon: Icons.close,
                  onTap: () => task.cancel(),
                  color: _kRed,
                ),
              ] else
                _Btn(
                  icon: Icons.remove,
                  onTap: () => manager.remove(task),
                ),
            ],
          ),
          const SizedBox(height: 5),
          _buildBottom(task, status, isActive),
        ],
      ),
    );
  }

  Widget _buildBottom(TransferTask task, TransferStatus status, bool isActive) {
    if (isActive) {
      return Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 3,
                backgroundColor: _kDivider,
                valueColor: AlwaysStoppedAnimation(
                  task.status == TransferStatus.paused ? _kFgMuted : _kBlue,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${(task.progress * 100).round()}%',
            style: const TextStyle(
                color: _kFgMuted, fontSize: 10, fontFamily: 'JetBrainsMono'),
          ),
        ],
      );
    }
    return switch (status) {
      TransferStatus.done => const Row(children: [
          Icon(Icons.check_circle_outline, size: 11, color: _kGreen),
          SizedBox(width: 4),
          Text('Done', style: TextStyle(color: _kGreen, fontSize: 11)),
        ]),
      TransferStatus.cancelled => const Row(children: [
          Icon(Icons.cancel_outlined, size: 11, color: _kFgMuted),
          SizedBox(width: 4),
          Text('Cancelled',
              style: TextStyle(color: _kFgMuted, fontSize: 11)),
        ]),
      TransferStatus.error => Row(children: [
          const Icon(Icons.error_outline, size: 11, color: _kRed),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              task.error ?? 'Error',
              style: const TextStyle(color: _kRed, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      _ => const SizedBox.shrink(),
    };
  }

}

class _Btn extends StatelessWidget {
  const _Btn({required this.icon, required this.onTap, this.color = _kFgMuted});

  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 20,
        height: 20,
        child: Icon(icon, size: 13, color: color),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mobile transfer bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

Future<void> showMobileTransferSheet({
  required BuildContext context,
  required TransferManager manager,
  bool frostedGlass = true,
  Color chromeBackground = const Color(0xFF161820),
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 48,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: _MobileTransferSheet(
        manager: manager,
        frostedGlass: frostedGlass,
        chromeBackground: chromeBackground,
      ),
    ),
    ),
  );
}

class _MobileTransferSheet extends StatelessWidget {
  const _MobileTransferSheet({
    required this.manager,
    this.frostedGlass = true,
    this.chromeBackground = const Color(0xFF161820),
  });

  final TransferManager manager;
  final bool frostedGlass;
  final Color chromeBackground;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(16));

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header
        ListenableBuilder(
          listenable: manager,
          builder: (_, _) => _MobileTransferSheetHeader(manager: manager),
        ),
        const Divider(height: 1, thickness: 1, color: _kDivider),
        // Transfer rows — capped at 5 visible, scrollable beyond that
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: kTransferListHeight),
          child: ListenableBuilder(
            listenable: manager,
            builder: (_, _) => _MobileTransferList(manager: manager),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );

    if (frostedGlass) {
      return ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xA0141416),
              borderRadius: radius,
            ),
            child: content,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: chromeBackground,
        borderRadius: radius,
      ),
      child: content,
    );
  }
}

class _MobileTransferSheetHeader extends StatelessWidget {
  const _MobileTransferSheetHeader({required this.manager});

  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    final tasks = manager.tasks;
    final active = tasks.where((t) => t.isActive).length;
    final hasDone = tasks.any((t) => !t.isActive);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      child: Row(
        children: [
          const Icon(
            Icons.swap_vert_rounded,
            size: 18,
            color: Color(0xFF2472C8),
          ),
          const SizedBox(width: 8),
          const Text(
            'Transfers',
            style: TextStyle(
              color: Color(0xFFD4D4D4),
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          if (active > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: _kBlue,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$active',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (hasDone)
            GestureDetector(
              onTap: manager.clearDone,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF252838),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Clear done',
                  style: TextStyle(
                    color: Color(0xFF8E8E8E),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MobileTransferList extends StatelessWidget {
  const _MobileTransferList({required this.manager});

  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    final tasks = manager.tasks;

    if (tasks.isEmpty) {
      return const SizedBox(
        height: 80,
        child: Center(
          child: Text(
            'No transfers',
            style: TextStyle(color: _kFgMuted, fontSize: 13),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shrinkWrap: true,
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 1),
      itemBuilder: (_, i) => _MobileTransferRow(
        task: tasks[i],
        manager: manager,
      ),
    );
  }
}

class _MobileTransferRow extends StatefulWidget {
  const _MobileTransferRow({
    required this.task,
    required this.manager,
  });

  final TransferTask task;
  final TransferManager manager;

  @override
  State<_MobileTransferRow> createState() => _MobileTransferRowState();
}

class _MobileTransferRowState extends State<_MobileTransferRow> {
  @override
  void initState() {
    super.initState();
    widget.task.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(_MobileTransferRow old) {
    super.didUpdateWidget(old);
    if (old.task != widget.task) {
      old.task.removeListener(_rebuild);
      widget.task.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.task.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final manager = widget.manager;
    final isUp = task.type == TransferType.upload;
    final status = task.status;
    final isActive = task.isActive;
    final isPaused = status == TransferStatus.paused;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF252838),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF353848), width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Direction icon
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0x1A2472C8)
                      : const Color(0xFF252838),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  isUp ? Icons.upload_rounded : Icons.download_rounded,
                  size: 15,
                  color: isActive ? _kBlue : _kFgMuted,
                ),
              ),
              const SizedBox(width: 10),
              // File name + size
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.name,
                      style: const TextStyle(
                        color: Color(0xFFD4D4D4),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _transferSizeLabel(task),
                      style: const TextStyle(
                        color: _kFgMuted,
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ],
                ),
              ),
              // Action buttons
              if (isActive) ...[
                _MobileBtn(
                  icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  onTap: isPaused ? task.resume : task.pause,
                ),
                const SizedBox(width: 4),
                _MobileBtn(
                  icon: Icons.close_rounded,
                  onTap: task.cancel,
                  color: _kRed,
                ),
              ] else
                _MobileBtn(
                  icon: Icons.remove_rounded,
                  onTap: () => manager.remove(task),
                ),
            ],
          ),
          // Progress / status
          if (isActive) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF252838),
                      valueColor: AlwaysStoppedAnimation(
                        isPaused ? _kFgMuted : _kBlue,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(task.progress * 100).round()}%',
                  style: const TextStyle(
                    color: _kFgMuted,
                    fontSize: 11,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 6),
            _buildStatusRow(status, task),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusRow(TransferStatus status, TransferTask task) {
    return switch (status) {
      TransferStatus.done => const Row(children: [
          Icon(Icons.check_circle_outline, size: 13, color: _kGreen),
          SizedBox(width: 5),
          Text('Done', style: TextStyle(color: _kGreen, fontSize: 12)),
        ]),
      TransferStatus.cancelled => const Row(children: [
          Icon(Icons.cancel_outlined, size: 13, color: _kFgMuted),
          SizedBox(width: 5),
          Text(
            'Cancelled',
            style: TextStyle(color: _kFgMuted, fontSize: 12),
          ),
        ]),
      TransferStatus.error => Row(children: [
          const Icon(Icons.error_outline, size: 13, color: _kRed),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              task.error ?? 'Error',
              style: const TextStyle(color: _kRed, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      _ => const SizedBox.shrink(),
    };
  }

}

class _MobileBtn extends StatelessWidget {
  const _MobileBtn({
    required this.icon,
    required this.onTap,
    this.color = _kFgMuted,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }
}
