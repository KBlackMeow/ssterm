import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/crt_settings.dart';

/// Wraps [child] with CRT monitor post-processing effects rendered entirely
/// in a [CustomPainter] — no BackdropFilter, no StackFit.expand, no setState.
///
/// Why no BackdropFilter:
///   BackdropFilter creates a compositing layer that is (re)connected to the
///   render tree synchronously.  On macOS this sometimes fires inside
///   MouseTracker._handleDeviceUpdate, violating its _debugDuringDeviceUpdate
///   invariant.  A plain CustomPaint overlay avoids this entirely.
///
/// Why no StackFit.expand:
///   The overlay can appear inside a ListView (e.g. TerminalPreview in the
///   settings sheet) where the parent provides unbounded height; expand would
///   propagate that infinite constraint to children and crash.  With the
///   default (loose) fit, the Stack sizes to widget.child and Positioned.fill
///   layers cover that exact area.
///
/// Animation is driven by [_CrtAnimNotifier] → CustomPainter.repaint, so only
/// paint() is called on each frame — never build() — which avoids any widget-
/// rebuild / hit-test interaction with the mouse tracker.
class CrtOverlay extends StatefulWidget {
  const CrtOverlay({
    super.key,
    required this.child,
    required this.settings,
  });

  final Widget child;
  final CrtSettings settings;

  @override
  State<CrtOverlay> createState() => _CrtOverlayState();
}

class _CrtOverlayState extends State<CrtOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _notifier = _CrtAnimNotifier();
  final _rng = math.Random();
  int _lastNoiseFrame = -1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _syncTicker();
  }

  @override
  void didUpdateWidget(CrtOverlay old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  void _syncTicker() {
    final s = widget.settings;
    final needsAnim =
        s.enabled && (s.flickerIntensity > 0 || s.noiseIntensity > 0);
    if (needsAnim && !_ticker.isActive) {
      _ticker.start();
    } else if (!needsAnim && _ticker.isActive) {
      _ticker.stop();
      _notifier.flickerOpacity = 1.0;
    }
  }

  void _onTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    var dirty = false;

    final fi = widget.settings.flickerIntensity;
    if (fi > 0) {
      final wave = math.sin(t * math.pi * 2 * 7.3) * 0.35 +
          math.sin(t * math.pi * 2 * 19.1) * 0.15;
      final rand = (_rng.nextDouble() - 0.5) * 0.5;
      final newOpacity = (1.0 - fi * 0.10 * (wave + rand + 1.0).abs())
          .clamp(1.0 - fi * 0.14, 1.0);
      if ((newOpacity - _notifier.flickerOpacity).abs() > 0.003) {
        _notifier.flickerOpacity = newOpacity;
        dirty = true;
      }
    }

    final ni = widget.settings.noiseIntensity;
    if (ni > 0) {
      final frame = (t * 18).floor();
      if (frame != _lastNoiseFrame) {
        _lastNoiseFrame = frame;
        _notifier.noisePhase = _rng.nextDouble();
        dirty = true;
      }
    }

    if (dirty) _notifier.markDirty();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    if (!s.enabled) return widget.child;

    final phosphorColor =
        s.phosphor == CrtPhosphor.white ? Colors.transparent : s.phosphor.color;

    // Stack with default fit (loose): sizes to widget.child, NOT to parent.
    // Positioned.fill layers cover that exact child area.
    Widget content = Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _CrtEffectsPainter(
                notifier: _notifier,
                scanlineOpacity: s.scanlineOpacity,
                vignetteIntensity: s.vignette,
                noiseIntensity: s.noiseIntensity,
                flickerIntensity: s.flickerIntensity,
                phosphorColor: phosphorColor,
                phosphorIntensity: s.glowIntensity,
              ),
            ),
          ),
        ),
      ],
    );

    if (s.curvature > 0) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(s.curvature * 30),
        child: content,
      );
    }

    return content;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _CrtAnimNotifier extends ChangeNotifier {
  double flickerOpacity = 1.0;
  double noisePhase = 0.0;

  void markDirty() => notifyListeners();
}

// ─────────────────────────────────────────────────────────────────────────────

class _CrtEffectsPainter extends CustomPainter {
  _CrtEffectsPainter({
    required this.notifier,
    required this.scanlineOpacity,
    required this.vignetteIntensity,
    required this.noiseIntensity,
    required this.flickerIntensity,
    required this.phosphorColor,
    required this.phosphorIntensity,
  }) : super(repaint: notifier);

  final _CrtAnimNotifier notifier;
  final double scanlineOpacity;
  final double vignetteIntensity;
  final double noiseIntensity;
  final double flickerIntensity;
  final Color phosphorColor;
  final double phosphorIntensity;

  @override
  void paint(Canvas canvas, Size size) {
    _paintScanlines(canvas, size);
    _paintVignette(canvas, size);
    _paintPhosphorTint(canvas, size);
    _paintNoise(canvas, size);
    _paintFlicker(canvas, size);
  }

  void _paintScanlines(Canvas canvas, Size size) {
    if (scanlineOpacity <= 0) return;
    final paint = Paint()..color = Color.fromRGBO(0, 0, 0, scanlineOpacity);
    for (double y = 0; y < size.height; y += 2) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  void _paintVignette(Canvas canvas, Size size) {
    if (vignetteIntensity <= 0) return;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1.05,
          colors: [
            Colors.transparent,
            Color.fromRGBO(0, 0, 0, vignetteIntensity * 0.82),
          ],
          stops: const [0.42, 1.0],
        ).createShader(rect),
    );
  }

  void _paintPhosphorTint(Canvas canvas, Size size) {
    if (phosphorIntensity <= 0 || phosphorColor == Colors.transparent) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = phosphorColor.withValues(alpha: phosphorIntensity * 0.09),
    );
  }

  void _paintNoise(Canvas canvas, Size size) {
    if (noiseIntensity <= 0 || notifier.noisePhase <= 0) return;
    final rng = math.Random((notifier.noisePhase * 0x7FFFFFFF).toInt());
    final dotCount = (noiseIntensity * 300).round();
    final paint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < dotCount; i++) {
      paint.color = Color.fromRGBO(
          255, 255, 255, rng.nextDouble() * noiseIntensity * 0.75);
      canvas.drawRect(
        Rect.fromLTWH(
          rng.nextDouble() * size.width,
          rng.nextDouble() * size.height,
          1.5,
          1.5,
        ),
        paint,
      );
    }
  }

  void _paintFlicker(Canvas canvas, Size size) {
    if (flickerIntensity <= 0) return;
    final dim = (1.0 - notifier.flickerOpacity).clamp(0.0, 1.0);
    if (dim < 0.001) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color.fromRGBO(0, 0, 0, dim),
    );
  }

  @override
  bool shouldRepaint(_CrtEffectsPainter old) =>
      old.notifier != notifier ||
      old.scanlineOpacity != scanlineOpacity ||
      old.vignetteIntensity != vignetteIntensity ||
      old.noiseIntensity != noiseIntensity ||
      old.flickerIntensity != flickerIntensity ||
      old.phosphorColor != phosphorColor ||
      old.phosphorIntensity != phosphorIntensity;
}
