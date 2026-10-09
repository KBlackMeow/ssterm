import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/startup_appearance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preloads the wallpaper before the first visible frame', () async {
    final dir = await Directory.systemTemp.createTemp('ssterm-wallpaper-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/wallpaper.png');
    await file.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l3sAAAAASUVORK5CYII=',
      ),
    );

    final provider = FileImage(file);
    expect(provider.obtainKey(ImageConfiguration.empty), isNotNull);
    expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);

    await preloadStartupWallpaper(file);

    expect(PaintingBinding.instance.imageCache.containsKey(provider), isTrue);
  });

  test('missing wallpaper never blocks startup', () async {
    await preloadStartupWallpaper(File('/nonexistent/ssterm-wallpaper.png'));
  });
}
