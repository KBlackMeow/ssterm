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
  });

  final File file;
  final double opacity;
  final double blur;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    Widget image = Image.file(
      file,
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );

    final sigma = blur.clamp(0.0, 64.0);
    if (sigma > 0) {
      image = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: image,
      );
    }

    return ClipRect(
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: image,
      ),
    );
  }
}
