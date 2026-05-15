import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/app_config.dart';
import 'sftp_view.dart';

const _kDivider = Color(0xFF3A3A3A);

class SshSessionView extends StatefulWidget {
  const SshSessionView({
    super.key,
    required this.terminal,
    required this.sftp,
    required this.host,
    required this.remotePath,
    required this.panelPosition,
    required this.onPanelPositionChanged,
    required this.theme,
    required this.textStyle,
  });

  final Terminal terminal;
  final SftpClient sftp;
  final String host;
  final ValueNotifier<String> remotePath;
  final SftpPanelPosition panelPosition;
  final ValueChanged<SftpPanelPosition> onPanelPositionChanged;
  final TerminalTheme theme;
  final TerminalStyle textStyle;

  @override
  State<SshSessionView> createState() => _SshSessionViewState();
}

class _SshSessionViewState extends State<SshSessionView> {
  static const _defaultRightWidth = 360.0;
  static const _minPanel = 160.0;
  static const _minTerminalHeight = 120.0;

  /// Default bottom split: terminal 3, SFTP 2.
  static const _bottomTerminalFlex = 3;
  static const _bottomSftpFlex = 2;

  late double _panelSize;
  bool _bottomSizeLocked = false;

  @override
  void initState() {
    super.initState();
    _panelSize = _defaultRightWidth;
    _bottomSizeLocked = false;
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
    final maxSftp = (totalHeight - _minTerminalHeight).clamp(_minPanel, totalHeight);
    final ratio = _bottomSftpFlex / (_bottomTerminalFlex + _bottomSftpFlex);
    return (totalHeight * ratio).clamp(_minPanel, maxSftp);
  }

  @override
  Widget build(BuildContext context) {
    final terminal = TerminalView(
      widget.terminal,
      theme: widget.theme,
      textStyle: widget.textStyle,
      padding: const EdgeInsets.all(6),
      autofocus: true,
      hardwareKeyboardOnly: true,
    );

    final sftpPanel = SftpView(
      sftp: widget.sftp,
      host: widget.host,
      remotePath: widget.remotePath,
      panelPosition: widget.panelPosition,
      onPanelPositionChanged: widget.onPanelPositionChanged,
    );

    return widget.panelPosition == SftpPanelPosition.right
        ? Row(
            children: [
              Expanded(child: terminal),
              _ResizeHandle(
                axis: Axis.horizontal,
                onDrag: (d) => setState(() {
                  _panelSize = (_panelSize - d).clamp(_minPanel, 600);
                }),
              ),
              SizedBox(width: _panelSize, child: sftpPanel),
            ],
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final total = constraints.maxHeight;
              final maxSftp =
                  (total - _minTerminalHeight).clamp(_minPanel, total);
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
        onPanUpdate: (d) => onDrag(
          axis == Axis.horizontal ? d.delta.dx : d.delta.dy,
        ),
        child: Container(
          width: axis == Axis.horizontal ? 4 : double.infinity,
          height: axis == Axis.vertical ? 4 : double.infinity,
          color: _kDivider,
        ),
      ),
    );
  }
}
