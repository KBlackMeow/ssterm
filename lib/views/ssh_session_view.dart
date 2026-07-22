import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../models/transfer_task.dart';
import '../widgets/frosted_glass.dart';
import 'sftp_view.dart';

const _kSftpPanelMargin = 8.0;

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
    this.onLayoutChanged,
    this.onOpenEditorTab,
  });

  final SftpClient sftp;
  final String host;
  final ValueNotifier<String> remotePath;
  final TransferManager transferManager;
  final bool sftpVisible;
  final VoidCallback onToggleSftp;
  final Widget child;
  final SftpPanelPosition initialPosition;
  final double? initialSize;
  final void Function(SftpPanelPosition position, double? size)? onLayoutChanged;

  /// Forwarded straight through to the embedded [SftpView] — see its
  /// doc comment for the contract.
  final void Function({
    required String path,
    required String initialContent,
    required DateTime? mtime,
  })? onOpenEditorTab;

  @override
  State<SshSessionView> createState() => _SshSessionViewState();
}

class _SshSessionViewState extends State<SshSessionView> {
  static const _kMinSide = 160.0;
  static const _kMaxFraction = 0.8;

  /// Default panel size when the user hasn't dragged the resize handle
  /// yet (`_customPanelSize == null`). A fixed pixel value rather than
  /// a fraction of the available width — the old `total * 2/5` default
  /// meant the panel visibly shrank whenever `total` shrank, which
  /// happens every time the AI Agent panel is also open (it's docked
  /// in a Row alongside this view and claims its own share of the
  /// window first, so this view's LayoutBuilder constraints are
  /// whatever's left over, not the full window). A constant size means
  /// the SFTP panel no longer reacts to what the AI panel is doing.
  static const _kDefaultPanelSize = 280.0;

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
    final maxSide = (total * _kMaxFraction).clamp(_kMinSide, double.infinity);
    if (_customPanelSize != null) {
      return _customPanelSize!.clamp(_kMinSide, maxSide);
    }
    // Still clamped to [_kMinSide, maxSide] — on a genuinely narrow
    // window/pane the panel still gives way rather than pushing the
    // terminal off-screen, but that's now a last-resort floor/ceiling
    // rather than the everyday behavior.
    return _kDefaultPanelSize.clamp(_kMinSide, maxSide);
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
          onOpenEditorTab: widget.onOpenEditorTab,
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
                          final current = _customPanelSize ?? panelSize;
                          _customPanelSize =
                              (current - d).clamp(_kMinSide, maxSide);
                          widget.onLayoutChanged
                              ?.call(_position, _customPanelSize);
                        }),
                      ),
                      Expanded(
                        child: _SftpFloatingChrome(
                          dockRight: true,
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
                          final current = _customPanelSize ?? panelSize;
                          _customPanelSize =
                              (current - d).clamp(_kMinSide, maxSide);
                          widget.onLayoutChanged
                              ?.call(_position, _customPanelSize);
                        }),
                      ),
                      Expanded(
                        child: _SftpFloatingChrome(
                          dockRight: false,
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
    required this.child,
  });

  final bool dockRight;
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

    final panelColor = AppColors.maybeOf(context)?.popup ?? FrostedGlassStyle.panelFillFrosted;
    return Padding(
      padding: margin,
      child: PopupSurface(
        color: panelColor,
        radius: FrostedGlassStyle.panelRadius,
        backdropBlur: 20,
        child: child,
      ),
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
          color: Colors.transparent,
        ),
      ),
    );
  }
}
