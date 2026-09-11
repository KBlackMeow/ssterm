import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const sourcePath = 'assets/icon/icon_new.png';

void main() {
  final source = img.decodePng(File(sourcePath).readAsBytesSync());
  if (source == null) {
    throw StateError('Unable to decode $sourcePath');
  }

  final squareSource = _cropSquare(source);
  final roundedSource = _roundCorners(squareSource);

  _writePng(roundedSource, 'assets/icon/icon.png', 1024);
  _writePng(squareSource, 'assets/icon/icon_ios.png', 1024);

  _writeWebIcons(roundedSource, squareSource);
  _writeAndroidIcons(roundedSource, squareSource);
  _writeAppleIcons(
    squareSource,
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
    'ios/Runner/Assets.xcassets/AppIcon.appiconset',
  );
  _writeMacIcons(
    roundedSource,
    'macos/Runner/Assets.xcassets/AppIcon.appiconset',
  );
  _writeWindowsIcon(roundedSource);

  stdout.writeln(
    'Generated app icons from $sourcePath '
    '(${source.width}x${source.height} -> ${squareSource.width}x${squareSource.height})',
  );
}

void _writeWebIcons(img.Image roundedSource, img.Image squareSource) {
  _writePng(roundedSource, 'web/favicon.png', 32);
  _writePng(roundedSource, 'web/icons/Icon-192.png', 192);
  _writePng(roundedSource, 'web/icons/Icon-512.png', 512);
  _writePng(squareSource, 'web/icons/Icon-maskable-192.png', 192);
  _writePng(squareSource, 'web/icons/Icon-maskable-512.png', 512);
}

void _writeAndroidIcons(img.Image roundedSource, img.Image squareSource) {
  const launcherSizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  const foregroundSizes = {
    'drawable-mdpi': 108,
    'drawable-hdpi': 162,
    'drawable-xhdpi': 216,
    'drawable-xxhdpi': 324,
    'drawable-xxxhdpi': 432,
  };

  for (final entry in launcherSizes.entries) {
    _writePng(
      roundedSource,
      'android/app/src/main/res/${entry.key}/ic_launcher.png',
      entry.value,
    );
  }
  for (final entry in foregroundSizes.entries) {
    _writePng(
      squareSource,
      'android/app/src/main/res/${entry.key}/ic_launcher_foreground.png',
      entry.value,
    );
  }
}

img.Image _cropSquare(img.Image source) {
  final side = math.min(source.width, source.height);
  return img.copyCrop(
    source,
    x: (source.width - side) ~/ 2,
    y: (source.height - side) ~/ 2,
    width: side,
    height: side,
  );
}

/// Adds transparent rounded corners for platforms that do not apply their own
/// icon mask. iOS and adaptive/maskable icons deliberately keep the full,
/// opaque source and let the operating system choose the final shape.
img.Image _roundCorners(img.Image source) {
  final out = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  final radius = math.min(source.width, source.height) * 0.22;
  final left = radius;
  final top = radius;
  final right = source.width - radius;
  final bottom = source.height - radius;

  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final px = x + 0.5;
      final py = y + 0.5;
      final nearestX = px.clamp(left, right);
      final nearestY = py.clamp(top, bottom);
      final dx = px - nearestX;
      final dy = py - nearestY;
      final distance = math.sqrt(dx * dx + dy * dy);
      final coverage = (radius + 0.5 - distance).clamp(0.0, 1.0);
      final pixel = source.getPixel(x, y);
      out.setPixelRgba(
        x,
        y,
        pixel.r,
        pixel.g,
        pixel.b,
        (pixel.a * coverage).round(),
      );
    }
  }
  return out;
}

void _writeAppleIcons(img.Image source, String contentsPath, String outputDir) {
  final contents = jsonDecode(File(contentsPath).readAsStringSync()) as Map;
  final images = contents['images'] as List;
  for (final item in images.cast<Map>()) {
    final filename = item['filename'] as String?;
    if (filename == null) continue;
    final size = _parsePointSize(item['size'] as String);
    final scale = _parseScale(item['scale'] as String);
    final pixels = (size * scale).round();
    _writePng(source, '$outputDir/$filename', pixels);
  }
}

void _writeMacIcons(img.Image source, String outputDir) {
  const sizes = {
    'app_icon_16.png': 16,
    'app_icon_32.png': 32,
    'app_icon_64.png': 64,
    'app_icon_128.png': 128,
    'app_icon_256.png': 256,
    'app_icon_512.png': 512,
    'app_icon_1024.png': 1024,
  };
  for (final entry in sizes.entries) {
    _writePng(source, '$outputDir/${entry.key}', entry.value);
  }
}

void _writeWindowsIcon(img.Image source) {
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  final frames = [
    for (final size in sizes)
      img.copyResize(
        source,
        width: size,
        height: size,
        interpolation: img.Interpolation.cubic,
      ),
  ];
  final ico = img.IcoEncoder().encodeImages(frames);
  File('windows/runner/resources/app_icon.ico').writeAsBytesSync(ico);
}

void _writePng(img.Image source, String path, int size) {
  final resized = img.copyResize(
    source,
    width: size,
    height: size,
    interpolation: img.Interpolation.cubic,
  );
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(resized));
}

double _parsePointSize(String size) {
  return double.parse(size.split('x').first);
}

int _parseScale(String scale) {
  return int.parse(scale.replaceAll('x', ''));
}
