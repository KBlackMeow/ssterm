import 'package:flutter/material.dart';

const _kDividerColor = Color(0xFF3A3A3A);
const _kDividerThickness = 4.0;

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
          final primaryW = totalW * _ratio - _kDividerThickness / 2;
          final secondaryW =
              totalW * (1 - _ratio) - _kDividerThickness / 2;
          return Row(
            children: [
              SizedBox(width: primaryW.clamp(0, totalW), child: widget.primary),
              _Handle(
                axis: Axis.horizontal,
                onDrag: (d) => _onDrag(d, totalW),
              ),
              SizedBox(
                width: secondaryW.clamp(0, totalW),
                child: widget.secondary,
              ),
            ],
          );
        },
      );
    } else {
      return LayoutBuilder(
        builder: (context, constraints) {
          final totalH = constraints.maxHeight;
          final primaryH = totalH * _ratio - _kDividerThickness / 2;
          final secondaryH =
              totalH * (1 - _ratio) - _kDividerThickness / 2;
          return Column(
            children: [
              SizedBox(height: primaryH.clamp(0, totalH), child: widget.primary),
              _Handle(
                axis: Axis.vertical,
                onDrag: (d) => _onDrag(d, totalH),
              ),
              SizedBox(
                height: secondaryH.clamp(0, totalH),
                child: widget.secondary,
              ),
            ],
          );
        },
      );
    }
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
        child: Container(
          width: axis == Axis.horizontal ? _kDividerThickness : double.infinity,
          height: axis == Axis.vertical ? _kDividerThickness : double.infinity,
          color: _kDividerColor,
        ),
      ),
    );
  }
}
