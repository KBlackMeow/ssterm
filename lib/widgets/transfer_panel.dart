import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
    return SizedBox(
      height: kTransferMenuHeight,
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: manager,
            builder: (_, _) => _TransferMenuHeader(manager: manager),
          ),
          const Divider(height: 1, thickness: 1, color: _kDivider),
          SizedBox(
            height: kTransferListHeight,
            child: ListenableBuilder(
              listenable: manager,
              builder: (_, _) => _TransferMenuListBody(manager: manager),
            ),
          ),
        ],
      ),
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
    if (!mounted) return;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (mounted) setState(() {});
    });
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
                _sizeLabel(task),
                style: const TextStyle(
                    color: _kFgMuted,
                    fontSize: 10,
                    fontFamily: 'Monaco'),
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
                color: _kFgMuted, fontSize: 10, fontFamily: 'Monaco'),
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

  static String _sizeLabel(TransferTask t) {
    if (t.total == 0) return _fmt(t.bytes);
    return '${_fmt(t.bytes)} / ${_fmt(t.total)}';
  }

  static String _fmt(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}K';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)}M';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)}G';
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
