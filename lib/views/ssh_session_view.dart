import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../models/transfer_task.dart';
import 'sftp_view.dart';

const _kDivider = Color(0xFF3A3A3A);

enum SftpPanelPosition { right, bottom }

/// Wraps [child] (terminal or split view) with a floating SFTP overlay panel.
class SshSessionView extends StatefulWidget {
  const SshSessionView({
    super.key,
    required this.sftp,
    required this.host,
    required this.remotePath,
    required this.transferManager,
    required this.sftpVisible,
    required this.onToggleSftp,
    required this.child,
  });

  final SftpClient sftp;
  final String host;
  final ValueNotifier<String> remotePath;
  final TransferManager transferManager;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final Widget child;

  @override
  State<SshSessionView> createState() => _SshSessionViewState();
}

class _SshSessionViewState extends State<SshSessionView> {
  static const _kDefaultSide = 360.0;
  static const _kMinSide = 160.0;
  static const _kMaxSide = 680.0;

  SftpPanelPosition _position = SftpPanelPosition.right;
  double _panelSize = _kDefaultSide;
  final _sftpKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final sftp = SftpView(
      key: _sftpKey,
      sftp: widget.sftp,
      host: widget.host,
      remotePath: widget.remotePath,
      transferManager: widget.transferManager,
      panelPosition: _position,
      onPanelPositionChanged: (pos) => setState(() {
        _position = pos;
        _panelSize = _kDefaultSide;
      }),
      onClose: widget.onToggleSftp,
    );

    final panel = _position == SftpPanelPosition.right
        ? Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _panelSize,
            child: Offstage(
              offstage: !widget.sftpVisible,
              child: Row(
                children: [
                  _ResizeHandle(
                    axis: Axis.horizontal,
                    onDrag: (d) => setState(() {
                      _panelSize = (_panelSize - d).clamp(_kMinSide, _kMaxSide);
                    }),
                  ),
                  Expanded(child: sftp),
                ],
              ),
            ),
          )
        : Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _panelSize,
            child: Offstage(
              offstage: !widget.sftpVisible,
              child: Column(
                children: [
                  _ResizeHandle(
                    axis: Axis.vertical,
                    onDrag: (d) => setState(() {
                      _panelSize = (_panelSize - d).clamp(_kMinSide, _kMaxSide);
                    }),
                  ),
                  Expanded(child: sftp),
                ],
              ),
            ),
          );

    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        panel,
      ],
    );
  }
}

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
