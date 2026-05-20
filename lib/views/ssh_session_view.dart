import 'dart:ui' show ImageFilter;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../models/transfer_task.dart';
import 'sftp_view.dart';

const _kSftpPanelRadius = 12.0;
const _kSftpPanelMargin = 8.0;
const _kSftpPanelFill = Color(0xD91C1C1C); // ~85% opacity
const _kSftpFrostedFill = Color(0x991C1C1C); // ~60% over blurred terminal
const _kSftpFrostedBlurSigma = 18.0;
const _kSftpPanelBorder = Color(0x1FFFFFFF);

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
    this.initialPosition = SftpPanelPosition.bottom,
    this.initialSize,
    this.frostedGlass = true,
    this.onLayoutChanged,
  });

  /// Default SFTP panel share of the session area (2/5 of width or height).
  static const defaultPanelFraction = 2 / 5;

  final SftpClient sftp;
  final String host;
  final ValueNotifier<String> remotePath;
  final TransferManager transferManager;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final Widget child;
  final SftpPanelPosition initialPosition;
  final double? initialSize;
  final bool frostedGlass;
  final void Function(SftpPanelPosition position, double? size)? onLayoutChanged;

  @override
  State<SshSessionView> createState() => _SshSessionViewState();
}

class _SshSessionViewState extends State<SshSessionView> {
  static const _kMinSide = 160.0;
  static const _kMaxFraction = 0.8;

  late SftpPanelPosition _position;
  double? _customPanelSize;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
    _customPanelSize = widget.initialSize;
  }
  final _sftpKey = GlobalKey();

  double _panelExtent(BoxConstraints constraints) {
    final total = _position == SftpPanelPosition.right
        ? constraints.maxWidth
        : constraints.maxHeight;
    final maxSide = total * _kMaxFraction;
    if (_customPanelSize != null) {
      return _customPanelSize!.clamp(_kMinSide, maxSide);
    }
    return (total * SshSessionView.defaultPanelFraction)
        .clamp(_kMinSide, maxSide);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panelSize = _panelExtent(constraints);

        final sftp = SftpView(
          key: _sftpKey,
          sftp: widget.sftp,
          host: widget.host,
          remotePath: widget.remotePath,
          transferManager: widget.transferManager,
          panelPosition: _position,
          onPanelPositionChanged: (pos) => setState(() {
            _position = pos;
            _customPanelSize = null;
            widget.onLayoutChanged?.call(_position, null);
          }),
          onClose: widget.onToggleSftp,
        );

        final panel = _position == SftpPanelPosition.right
            ? Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: panelSize,
                child: Offstage(
                  offstage: !widget.sftpVisible,
                  child: Row(
                    children: [
                      _ResizeHandle(
                        axis: Axis.horizontal,
                        onDrag: (d) => setState(() {
                          final maxSide = constraints.maxWidth * _kMaxFraction;
                          _customPanelSize =
                              (panelSize - d).clamp(_kMinSide, maxSide);
                          widget.onLayoutChanged
                              ?.call(_position, _customPanelSize);
                        }),
                      ),
                      Expanded(
                        child: _SftpFloatingChrome(
                          dockRight: true,
                          frostedGlass: widget.frostedGlass,
                          child: sftp,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: panelSize,
                child: Offstage(
                  offstage: !widget.sftpVisible,
                  child: Column(
                    children: [
                      _ResizeHandle(
                        axis: Axis.vertical,
                        onDrag: (d) => setState(() {
                          final maxSide =
                              constraints.maxHeight * _kMaxFraction;
                          _customPanelSize =
                              (panelSize - d).clamp(_kMinSide, maxSide);
                          widget.onLayoutChanged
                              ?.call(_position, _customPanelSize);
                        }),
                      ),
                      Expanded(
                        child: _SftpFloatingChrome(
                          dockRight: false,
                          frostedGlass: widget.frostedGlass,
                          child: sftp,
                        ),
                      ),
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
      },
    );
  }
}

/// Rounded, semi-transparent SFTP card over the terminal.
class _SftpFloatingChrome extends StatelessWidget {
  const _SftpFloatingChrome({
    required this.dockRight,
    required this.frostedGlass,
    required this.child,
  });

  final bool dockRight;
  final bool frostedGlass;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final margin = dockRight
        ? const EdgeInsets.fromLTRB(0, _kSftpPanelMargin, _kSftpPanelMargin, _kSftpPanelMargin)
        : const EdgeInsets.fromLTRB(
            _kSftpPanelMargin,
            0,
            _kSftpPanelMargin,
            _kSftpPanelMargin,
          );

    final radius = BorderRadius.circular(_kSftpPanelRadius);
    final decoration = BoxDecoration(
      color: frostedGlass ? _kSftpFrostedFill : _kSftpPanelFill,
      border: Border.all(color: _kSftpPanelBorder),
      borderRadius: radius,
    );

    Widget panel = DecoratedBox(decoration: decoration, child: child);

    panel = ClipRRect(
      borderRadius: radius,
      child: frostedGlass
          ? BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: _kSftpFrostedBlurSigma,
                sigmaY: _kSftpFrostedBlurSigma,
              ),
              child: panel,
            )
          : panel,
    );

    return Padding(padding: margin, child: panel);
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
          color: Colors.transparent,
        ),
      ),
    );
  }
}
