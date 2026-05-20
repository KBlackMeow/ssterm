import 'package:flutter/material.dart';

const _kHandleThickness = 6.0;

class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.primary,
    required this.secondary,
    required this.axis,
    this.initialRatio = 0.5,
    this.minRatio = 0.2,
    this.maxRatio = 0.8,
  });

  final Widget primary;
  final Widget secondary;
  final Axis axis;
  final double initialRatio;
  final double minRatio;
  final double maxRatio;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  late double _ratio;

  @override
  void initState() {
    super.initState();
    _ratio = widget.initialRatio;
  }

  @override
  void didUpdateWidget(SplitView old) {
    super.didUpdateWidget(old);
    if (old.axis != widget.axis) _ratio = widget.initialRatio;
  }

  void _onDrag(double delta, double total) {
    if (total <= 0) return;
    setState(() {
      _ratio = (_ratio + delta / total).clamp(widget.minRatio, widget.maxRatio);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.axis == Axis.horizontal) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final totalW = constraints.maxWidth;
          final splitX = (totalW * _ratio).clamp(0.0, totalW);
          return Stack(
            children: [
              Row(
                children: [
                  SizedBox(width: splitX, child: widget.primary),
                  Expanded(child: widget.secondary),
                ],
              ),
              Positioned(
                left: (splitX - _kHandleThickness / 2)
                    .clamp(0.0, totalW - _kHandleThickness),
                top: 0,
                bottom: 0,
                width: _kHandleThickness,
                child: _Handle(
                  axis: Axis.horizontal,
                  onDrag: (d) => _onDrag(d, totalW),
                ),
              ),
            ],
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalH = constraints.maxHeight;
        final splitY = (totalH * _ratio).clamp(0.0, totalH);
        return Stack(
          children: [
            Column(
              children: [
                SizedBox(height: splitY, child: widget.primary),
                Expanded(child: widget.secondary),
              ],
            ),
            Positioned(
              top: (splitY - _kHandleThickness / 2)
                  .clamp(0.0, totalH - _kHandleThickness),
              left: 0,
              right: 0,
              height: _kHandleThickness,
              child: _Handle(
                axis: Axis.vertical,
                onDrag: (d) => _onDrag(d, totalH),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({required this.axis, required this.onDrag});

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
        child: const SizedBox.expand(),
      ),
    );
  }
}
