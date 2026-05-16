import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/crt_settings.dart';

/// Wraps [child] with CRT monitor post-processing effects rendered entirely
/// in a [CustomPainter] — no BackdropFilter, no StackFit.expand, no setState.
///
/// Why no BackdropFilter:
///   BackdropFilter creates a compositing layer that is (re)connected to the
///   render tree synchronously. On macOS this sometimes fires inside
///   MouseTracker._handleDeviceUpdate, violating its _debugDuringDeviceUpdate
///   invariant. A plain CustomPaint overlay avoids this entirely.
///
/// Why no StackFit.expand:
///   The overlay can appear inside a ListView (e.g. TerminalPreview in the
///   settings sheet) where the parent provides unbounded height; expand would
///   propagate that infinite constraint to children and crash. With the
///   default (loose) fit, the Stack sizes to widget.child and Positioned.fill
///   layers cover that exact area.
///
/// Animation is driven by a low-frequency timer so only paint() runs on each
/// frame that actually changes, which keeps CPU use much lower than the old
/// full-rate per-pixel repaint path.
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

class _CrtOverlayState extends State<CrtOverlay> {
  final _notifier = _CrtAnimNotifier();
  final _rng = math.Random();
  Timer? _timer;
  int _tick = 0;
  double _noisePhase = 0.0;
  ui.Image? _scanlineImage;
  ui.Image? _noiseImage;
  _ScanlineKey? _scanlineKey;
  _NoiseKey? _noiseKey;

  @override
  void initState() {
    super.initState();
    _refreshTextures();
    _syncTicker();
  }

  @override
  void didUpdateWidget(CrtOverlay old) {
    super.didUpdateWidget(old);
    if (_needsTextureRefresh(old.settings, widget.settings)) {
      _refreshTextures();
    }
    _syncTicker();
  }

  bool _needsTextureRefresh(CrtSettings old, CrtSettings next) =>
      old.enabled != next.enabled ||
      old.scanlineOpacity != next.scanlineOpacity ||
      old.noiseIntensity != next.noiseIntensity;

  void _syncTicker() {
    final s = widget.settings;
    final needsAnim =
        s.enabled && (s.flickerIntensity > 0 || s.noiseIntensity > 0);
    if (needsAnim && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 140), _onTick);
    } else if (!needsAnim && _timer != null) {
      _timer?.cancel();
      _timer = null;
      _tick = 0;
      _noisePhase = 0.0;
      _notifier.flickerOpacity = 1.0;
      _notifier.noisePhase = 0.0;
    }
  }

  Future<void> _refreshTextures() async {
    final s = widget.settings;
    if (!s.enabled) return;

    final scanlineKey = _ScanlineKey.fromOpacity(s.scanlineOpacity);
    if (_scanlineKey != scanlineKey) {
      _scanlineKey = scanlineKey;
      final image = await _createScanlineImage(s.scanlineOpacity);
      if (!mounted || _scanlineKey != scanlineKey) return;
      _scanlineImage?.dispose();
      _scanlineImage = image;
      if (mounted) setState(() {});
    }

    final noiseKey = _NoiseKey.fromIntensity(s.noiseIntensity);
    if (_noiseKey != noiseKey) {
      _noiseKey = noiseKey;
      final seed = _rng.nextInt(0x7fffffff);
      final image = await _createNoiseImage(s.noiseIntensity, seed);
      if (!mounted || _noiseKey != noiseKey) return;
      _noiseImage?.dispose();
      _noiseImage = image;
      if (mounted) setState(() {});
    }
  }

  void _onTick(Timer _) {
    final s = widget.settings;
    if (!s.enabled) return;

    _tick += 1;
    final t = _tick * 0.09;
    var dirty = false;

    final fi = s.flickerIntensity;
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

    final ni = s.noiseIntensity;
    if (ni > 0 && (_tick & 1) == 0) {
      _noisePhase = (_noisePhase + (0.75 + ni * 0.55)) % 256.0;
      _notifier.noisePhase = _noisePhase;
      dirty = true;
    }

    if (dirty) _notifier.markDirty();
  }

  Future<ui.Image> _createScanlineImage(double opacity) async {
    final alpha = (opacity.clamp(0.0, 0.6) * 255).round();
    final pixels = Uint8List.fromList([
      0, 0, 0, 0,
      0, 0, 0, alpha,
    ]);
    return _decodeImage(pixels, 1, 2);
  }

  Future<ui.Image> _createNoiseImage(double intensity, int seed) async {
    const size = 128;
    final pixels = Uint8List(size * size * 4);
    final threshold = (intensity.clamp(0.0, 1.0) * 255).round();

    var index = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final hash = _hashNoise(seed, x, y);
        final active = hash & 0xff;
        if (active < threshold) {
          final alpha = 32 + (hash >> 8) % 160;
          pixels[index] = 255;
          pixels[index + 1] = 255;
          pixels[index + 2] = 255;
          pixels[index + 3] = alpha;
        }
        index += 4;
      }
    }
    return _decodeImage(pixels, size, size);
  }

  int _hashNoise(int seed, int x, int y) {
    var n = seed ^ (x * 374761393) ^ (y * 668265263);
    n = (n ^ (n >> 13)) * 1274126177;
    return n ^ (n >> 16);
  }

  Future<ui.Image> _decodeImage(Uint8List pixels, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: width * 4,
    );
    return completer.future;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scanlineImage?.dispose();
    _noiseImage?.dispose();
    _notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    if (!s.enabled) return widget.child;

    final phosphorColor =
        s.phosphor == CrtPhosphor.white ? Colors.transparent : s.phosphor.color;

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
                scanlineImage: _scanlineImage,
                noiseImage: _noiseImage,
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
    required this.scanlineImage,
    required this.noiseImage,
  }) : super(repaint: notifier);

  final _CrtAnimNotifier notifier;
  final double scanlineOpacity;
  final double vignetteIntensity;
  final double noiseIntensity;
  final double flickerIntensity;
  final Color phosphorColor;
  final double phosphorIntensity;
  final ui.Image? scanlineImage;
  final ui.Image? noiseImage;

  static final _PaintCache<_StaticLayerKey> _staticLayerCache = _PaintCache(12);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    _paintScanlines(canvas, size);

    final staticLayer = _staticLayerCache.obtain(
      _StaticLayerKey(
        width: size.width.round(),
        height: size.height.round(),
        vignetteKey: (vignetteIntensity * 1000).round(),
        phosphorKey: phosphorColor.toARGB32(),
        phosphorIntensityKey: (phosphorIntensity * 1000).round(),
      ),
      () => _buildStaticLayer(size),
    );
    canvas.drawPicture(staticLayer);

    _paintNoise(canvas, size);
    _paintFlicker(canvas, size);
  }

  void _paintScanlines(Canvas canvas, Size size) {
    if (scanlineOpacity <= 0) return;
    if (scanlineImage != null) {
      final shader = ui.ImageShader(
        scanlineImage!,
        ui.TileMode.repeated,
        ui.TileMode.repeated,
        Matrix4.identity().storage,
      );
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      return;
    }

    final paint = Paint()..color = Color.fromRGBO(0, 0, 0, scanlineOpacity);
    for (double y = 0; y < size.height; y += 2) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  ui.Picture _buildStaticLayer(Size size) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    _paintVignette(canvas, size);
    _paintPhosphorTint(canvas, size);
    return recorder.endRecording();
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
    if (noiseIntensity <= 0 || noiseImage == null) return;

    final shader = ui.ImageShader(
      noiseImage!,
      ui.TileMode.repeated,
      ui.TileMode.repeated,
      (Matrix4.identity()
            ..translateByDouble(
              notifier.noisePhase * 0.65,
              notifier.noisePhase * 0.31,
              0,
              1.0,
            ))
          .storage,
    );

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = shader
        ..color = Colors.white.withValues(alpha: noiseIntensity * 0.08),
    );
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
      old.phosphorIntensity != phosphorIntensity ||
      old.scanlineImage != scanlineImage ||
      old.noiseImage != noiseImage;
}

class _ScanlineKey {
  const _ScanlineKey(this.opacityKey);

  factory _ScanlineKey.fromOpacity(double opacity) =>
      _ScanlineKey((opacity * 1000).round());

  final int opacityKey;

  @override
  bool operator ==(Object other) =>
      other is _ScanlineKey && other.opacityKey == opacityKey;

  @override
  int get hashCode => opacityKey.hashCode;
}

class _NoiseKey {
  const _NoiseKey(this.intensityKey);

  factory _NoiseKey.fromIntensity(double intensity) =>
      _NoiseKey((intensity * 1000).round());

  final int intensityKey;

  @override
  bool operator ==(Object other) =>
      other is _NoiseKey && other.intensityKey == intensityKey;

  @override
  int get hashCode => intensityKey.hashCode;
}

class _StaticLayerKey {
  const _StaticLayerKey({
    required this.width,
    required this.height,
    required this.vignetteKey,
    required this.phosphorKey,
    required this.phosphorIntensityKey,
  });

  final int width;
  final int height;
  final int vignetteKey;
  final int phosphorKey;
  final int phosphorIntensityKey;

  @override
  bool operator ==(Object other) =>
      other is _StaticLayerKey &&
      other.width == width &&
      other.height == height &&
      other.vignetteKey == vignetteKey &&
      other.phosphorKey == phosphorKey &&
      other.phosphorIntensityKey == phosphorIntensityKey;

  @override
  int get hashCode => Object.hash(
        width,
        height,
        vignetteKey,
        phosphorKey,
        phosphorIntensityKey,
      );
}

class _PaintCache<K> {
  _PaintCache(this.maxEntries);

  final int maxEntries;
  final _entries = <K, ui.Picture>{};

  ui.Picture obtain(K key, ui.Picture Function() create) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing;
    }

    final picture = create();
    _entries[key] = picture;
    if (_entries.length > maxEntries) {
      final oldestKey = _entries.keys.first;
      _entries.remove(oldestKey);
    }
    return picture;
  }
}
