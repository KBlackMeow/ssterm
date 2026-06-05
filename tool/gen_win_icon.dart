// Generates a multi-resolution Windows .ico from the high-res source PNG.
// Run with: dart run tool/gen_win_icon.dart
import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final src = img.decodePng(File('assets/icon/icon.png').readAsBytesSync())!;
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  final frames = [
    for (final s in sizes)
      img.copyResize(src,
          width: s, height: s, interpolation: img.Interpolation.cubic)
  ];
  final ico = img.IcoEncoder().encodeImages(frames);
  File('windows/runner/resources/app_icon.ico').writeAsBytesSync(ico);
  stdout.writeln('Wrote app_icon.ico with sizes: $sizes');
}
