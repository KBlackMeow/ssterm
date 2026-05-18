import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/app_config.dart';
import '../models/terminal_settings.dart';
import '../models/transfer_task.dart';
import '../widgets/terminal_surface.dart';
import 'sftp_view.dart';

const _kDivider = Color(0xFF3A3A3A);

class SshSessionView extends StatefulWidget {
  const SshSessionView({
    super.key,
    required this.terminal,
    required this.sftp,
    required this.host,
    required this.remotePath,
    required this.transferManager,
    required this.panelPosition,
    required this.onPanelPositionChanged,
    required this.terminalSettings,
    required this.sftpVisible,
    required this.onToggleSftp,
    this.terminalViewKey,
    this.contextMenu,
  });

  final Terminal terminal;
  final SftpClient sftp;
  final String host;
  final ValueNotifier<String> remotePath;
  final TransferManager transferManager;
  final SftpPanelPosition panelPosition;
  final ValueChanged<SftpPanelPosition> onPanelPositionChanged;
  final TerminalSettings terminalSettings;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final GlobalKey<TerminalViewState>? terminalViewKey;
  final TerminalContextMenuConfig? contextMenu;

  @override
  State<SshSessionView> createState() => _SshSessionViewState();
}

class _SshSessionViewState extends State<SshSessionView> {
  static const _defaultRightWidth = 360.0;
  static const _minPanel = 160.0;
  static const _minTerminalHeight = 120.0;
  static const _bottomTerminalFlex = 3;
  static const _bottomSftpFlex = 2;

  late double _panelSize;
  bool _bottomSizeLocked = false;
  final _sftpKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _panelSize = _defaultRightWidth;
  }

  @override
  void didUpdateWidget(covariant SshSessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.panelPosition != widget.panelPosition) {
      if (widget.panelPosition == SftpPanelPosition.right) {
        _panelSize = _defaultRightWidth;
      } else {
        _bottomSizeLocked = false;
      }
    }
  }

  double _bottomPanelHeight(double totalHeight) {
    final maxSftp =
        (totalHeight - _minTerminalHeight).clamp(_minPanel, totalHeight);
    final ratio = _bottomSftpFlex / (_bottomTerminalFlex + _bottomSftpFlex);
    return (totalHeight * ratio).clamp(_minPanel, maxSftp);
  }

  @override
  Widget build(BuildContext context) {
    final terminal = TerminalSurface(
      terminal: widget.terminal,
      settings: widget.terminalSettings,
      viewKey: widget.terminalViewKey,
      contextMenu: widget.contextMenu,
    );

    final sftpPanel = SftpView(
      key: _sftpKey,
      sftp: widget.sftp,
      host: widget.host,
      remotePath: widget.remotePath,
      transferManager: widget.transferManager,
      panelPosition: widget.panelPosition,
      onPanelPositionChanged: widget.onPanelPositionChanged,
      onClose: widget.onToggleSftp,
    );

    if (!widget.sftpVisible) {
      return Stack(
        children: [
          Positioned.fill(child: terminal),
          Offstage(offstage: true, child: sftpPanel),
        ],
      );
    }

    if (widget.panelPosition == SftpPanelPosition.right) {
      return Row(
        children: [
          Expanded(child: terminal),
          _ResizeHandle(
            axis: Axis.horizontal,
            onDrag: (d) =>
                setState(() => _panelSize = (_panelSize - d).clamp(_minPanel, 600)),
          ),
          SizedBox(width: _panelSize, child: sftpPanel),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxHeight;
        final maxSftp = (total - _minTerminalHeight).clamp(_minPanel, total);
        final sftpHeight = _bottomSizeLocked
            ? _panelSize.clamp(_minPanel, maxSftp)
            : _bottomPanelHeight(total);

        return Column(
          children: [
            Expanded(child: terminal),
            _ResizeHandle(
              axis: Axis.vertical,
              onDrag: (d) => setState(() {
                if (!_bottomSizeLocked) {
                  _bottomSizeLocked = true;
                  _panelSize = sftpHeight;
                }
                _panelSize = (_panelSize - d).clamp(_minPanel, maxSftp);
              }),
            ),
            SizedBox(height: sftpHeight, child: sftpPanel),
          ],
        );
      },
    );
  }
}

// ── Resize handle ─────────────────────────────────────────────────────────────
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.axis, required this.onDrag});

  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: axis == Axis.horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) =>
            onDrag(axis == Axis.horizontal ? d.delta.dx : d.delta.dy),
        child: Container(
          width: axis == Axis.horizontal ? 4 : double.infinity,
          height: axis == Axis.vertical ? 4 : double.infinity,
          color: _kDivider,
        ),
      ),
    );
  }
}
