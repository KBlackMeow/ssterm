import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const sourcePath = 'assets/icon/icon.png';

void main() {
  final source = img.decodePng(File(sourcePath).readAsBytesSync());
  if (source == null) {
    throw StateError('Unable to decode $sourcePath');
  }

  final iosSource = _makeIosSource(source);
  final opaqueSource = _flatten(source);

  _writePng(iosSource, 'assets/icon/icon_ios.png', 1024);

  _writeWebIcons(source);
  _writeAndroidIcons(source);
  _writeAppleIcons(
    iosSource,
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
    'ios/Runner/Assets.xcassets/AppIcon.appiconset',
  );
  _writeMacIcons(
    opaqueSource,
    'macos/Runner/Assets.xcassets/AppIcon.appiconset',
  );
  _writeWindowsIcon(source);

  stdout.writeln('Generated app icons from $sourcePath');
}

void _writeWebIcons(img.Image source) {
  _writePng(source, 'web/favicon.png', 32);
  _writePng(source, 'web/icons/Icon-192.png', 192);
  _writePng(source, 'web/icons/Icon-512.png', 512);
  _writePng(source, 'web/icons/Icon-maskable-192.png', 192);
  _writePng(source, 'web/icons/Icon-maskable-512.png', 512);
}

void _writeAndroidIcons(img.Image source) {
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
      source,
      'android/app/src/main/res/${entry.key}/ic_launcher.png',
      entry.value,
    );
  }
  for (final entry in foregroundSizes.entries) {
    _writePng(
      source,
      'android/app/src/main/res/${entry.key}/ic_launcher_foreground.png',
      entry.value,
    );
  }
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
    _writePng(source, '$outputDir/${entry.key}', entry.value, flatten: true);
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

void _writePng(
  img.Image source,
  String path,
  int size, {
  bool flatten = false,
}) {
  final resized = img.copyResize(
    flatten ? _flatten(source) : source,
    width: size,
    height: size,
    interpolation: img.Interpolation.cubic,
  );
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(resized));
}

img.Image _flatten(img.Image source) {
  final background = img.Image(width: source.width, height: source.height);
  final width = source.width;
  final height = source.height;
  final nearest = List<int>.filled(width * height, -1);
  final queue = List<int>.filled(width * height, 0);
  var head = 0;
  var tail = 0;

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = y * width + x;
      final p = source.getPixel(x, y);
      if (p.a >= 250) {
        nearest[index] = index;
        queue[tail++] = index;
      }
    }
  }

  void add(int x, int y, int seed) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final index = y * width + x;
    if (nearest[index] != -1) return;
    nearest[index] = seed;
    queue[tail++] = index;
  }

  while (head < tail) {
    final index = queue[head++];
    final seed = nearest[index];
    final x = index % width;
    final y = index ~/ width;
    add(x + 1, y, seed);
    add(x - 1, y, seed);
    add(x, y + 1, seed);
    add(x, y - 1, seed);
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = y * width + x;
      final p = source.getPixel(x, y);
      final seed = nearest[index];
      final fill = seed == -1
          ? source.getPixel(width ~/ 2, height ~/ 2)
          : source.getPixel(seed % width, seed ~/ width);
      final a = p.a / 255.0;
      final r = (p.r * a + fill.r * (1 - a)).round();
      final g = (p.g * a + fill.g * (1 - a)).round();
      final b = (p.b * a + fill.b * (1 - a)).round();
      background.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  final smoothed = img.gaussianBlur(background, radius: 48);
  final out = img.Image(width: width, height: height);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = source.getPixel(x, y);
      final fill = smoothed.getPixel(x, y);
      final a = p.a / 255.0;
      final r = (p.r * a + fill.r * (1 - a)).round();
      final g = (p.g * a + fill.g * (1 - a)).round();
      final b = (p.b * a + fill.b * (1 - a)).round();
      out.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return out;
}

img.Image _makeIosSource(img.Image source) {
  final width = source.width;
  final height = source.height;
  final out = img.Image(width: width, height: height);

  for (var y = 0; y < height; y++) {
    final ny = y / (height - 1);
    for (var x = 0; x < width; x++) {
      final nx = x / (width - 1);
      final dx = nx - 0.38;
      final dy = ny - 0.28;
      final glow = math.max(0.0, 1.0 - math.sqrt(dx * dx + dy * dy) / 0.95);

      final br = (4 + 9 * (1 - ny) + 4 * (1 - nx) + 5 * glow).round();
      final bg = (15 + 11 * (1 - ny) + 3 * (1 - nx) + 5 * glow).round();
      final bb = (30 + 18 * (1 - ny) + 4 * (1 - nx) + 8 * glow).round();
      out.setPixelRgba(x, y, br, bg, bb, 255);
    }
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final p = source.getPixel(x, y);
      if (!_isIosForeground(p)) continue;
      final fill = out.getPixel(x, y);
      final a = p.a / 255.0;
      final r = (p.r * a + fill.r * (1 - a)).round();
      final g = (p.g * a + fill.g * (1 - a)).round();
      final b = (p.b * a + fill.b * (1 - a)).round();
      out.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  return out;
}

bool _isIosForeground(img.Pixel p) {
  if (p.a < 24) return false;
  final maxChannel = math.max(p.r, math.max(p.g, p.b));
  final minChannel = math.min(p.r, math.min(p.g, p.b));
  final isWhite = minChannel >= 150 && maxChannel - minChannel <= 85;
  final isGreen = p.g >= 115 && p.g > p.r + 35 && p.g > p.b + 10;
  return isWhite || isGreen;
}

double _parsePointSize(String size) {
  return double.parse(size.split('x').first);
}

int _parseScale(String scale) {
  return int.parse(scale.replaceAll('x', ''));
}
