import 'package:flutter/material.dart';

import '../models/transfer_task.dart';

const _kDivider = Color(0xFF3A3A3A);
const _kFgActive = Color(0xFFD4D4D4);
const _kFgMuted = Color(0xFF8E8E8E);
const _kBlue = Color(0xFF2472C8);
const _kRed = Color(0xFFFF6E67);
const _kGreen = Color(0xFF4EC9B0);

/// Content widget embedded inside a showMenu popup.
class TransferMenuContent extends StatelessWidget {
  const TransferMenuContent({super.key, required this.manager});

  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (_, _) {
        final tasks = manager.tasks;
        final active = tasks.where((t) => t.isActive).length;
        final hasDone = tasks.any((t) => !t.isActive);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── header ──────────────────────────────────────────────────
            SizedBox(
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
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
            ),
            const Divider(height: 1, thickness: 1, color: _kDivider),
            // ── list ────────────────────────────────────────────────────
            if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                child: Text(
                  'No transfers',
                  style: TextStyle(color: _kFgMuted, fontSize: 12),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int i = 0; i < tasks.length; i++) ...[
                        if (i > 0)
                          const Divider(
                              height: 1, thickness: 1, color: _kDivider),
                        _TransferRow(task: tasks[i], manager: manager),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.task, required this.manager});

  final TransferTask task;
  final TransferManager manager;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: task,
      builder: (_, _) {
        final isUp = task.type == TransferType.upload;
        final status = task.status;
        final isActive = task.isActive;
        final isPaused = status == TransferStatus.paused;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
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
                      style: const TextStyle(
                          color: _kFgActive, fontSize: 13),
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
              _buildBottom(status, isActive),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottom(TransferStatus status, bool isActive) {
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

  String _sizeLabel(TransferTask t) {
    if (t.total == 0) return _fmt(t.bytes);
    return '${_fmt(t.bytes)} / ${_fmt(t.total)}';
  }

  String _fmt(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}K';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)}M';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)}G';
  }
}

class _Btn extends StatefulWidget {
  const _Btn({required this.icon, required this.onTap, this.color = _kFgMuted});

  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 13,
            color: _hover ? _kFgActive : widget.color,
          ),
        ),
      ),
    );
  }
}
