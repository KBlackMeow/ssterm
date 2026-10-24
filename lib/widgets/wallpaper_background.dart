import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Full-bleed wallpaper layer with optional Gaussian blur and opacity.
class WallpaperBackground extends StatelessWidget {
  const WallpaperBackground({
    super.key,
    required this.file,
    required this.opacity,
    this.blur = 0,
    this.fit = BoxFit.cover,
    this.backdropColor,
  });

  final File file;
  final double opacity;
  final double blur;
  final BoxFit fit;

  /// Paint an opaque base only once the image is available. Before that, the
  /// transparent surface reveals the native startup wallpaper underneath.
  final Color? backdropColor;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      file,
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        Widget image = child;
        final sigma = blur.clamp(0.0, 64.0);
        if (sigma > 0) {
          image = ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: image,
          );
        }
        image = ClipRect(
          child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: image),
        );
        if (backdropColor != null && frame != null) {
          return ColoredBox(color: backdropColor!, child: image);
        }
        return image;
      },
    );
  }
}
