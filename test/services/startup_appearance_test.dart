import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming, PictureRecorder, Canvas, Paint;

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/startup_appearance.dart';
import 'package:ssterm/models/terminal_settings.dart';
import 'package:ssterm/widgets/wallpaper_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'startup brightness stays unchanged when the wallpaper becomes ready',
    (tester) async {
      final file = File('/unused/ssterm-controlled-wallpaper.png');
      final provider = FileImage(file);
      final decoded = Completer<ImageInfo>();
      PaintingBinding.instance.imageCache.putIfAbsent(
        provider,
        () => OneFrameImageStreamCompleter(decoded.future),
      );
      addTearDown(() {
        PaintingBinding.instance.imageCache.evict(provider);
      });
      final usingNative = ValueNotifier(true);
      addTearDown(usingNative.dispose);
      final settings = TerminalSettings(
        wallpaperId: 'controlled.png',
        wallpaperEnabled: true,
        wallpaperBlur: 0,
        wallpaperOpacity: 1,
        backgroundOpacity: 0.5,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox.square(
              dimension: 20,
              child: ValueListenableBuilder<bool>(
                valueListenable: usingNative,
                builder: (context, pending, _) {
                  final display = terminalSettingsForBackdrop(
                    settings,
                    nativeWallpaperVisible: pending,
                  );
                  return RepaintBoundary(
                    key: key,
                    child: ColoredBox(
                      // Native white wallpaper already shaded by 50% #1E1E1E.
                      color: const Color(0xFF8F8F8F),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          WallpaperBackground(
                            file: file,
                            opacity: 1,
                            blur: 0,
                            backdropColor: const Color(0xFF1E1E1E),
                          ),
                          ColoredBox(color: display.chromeBackground),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      Future<int?> redChannel() async {
        final image = boundary.toImageSync();
        final data = await image.toByteData();
        image.dispose();
        return data?.getUint8(0);
      }

      expect(await tester.runAsync(redChannel), closeTo(143, 1));
      final recorder = PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(1, 1);
      picture.dispose();
      decoded.complete(ImageInfo(image: image));
      usingNative.value = false;
      await tester.pumpAndSettle();
      expect(await tester.runAsync(redChannel), closeTo(143, 1));
    },
  );

  testWidgets(
    'terminal controls paint while the wallpaper handoff is pending',
    (tester) async {
      var completed = false;
      final handoff = waitForStartupWallpaperFrame(tester.binding).then((_) {
        completed = true;
      });
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('Terminal controls'),
        ),
      );
      expect(find.text('Terminal controls'), findsOneWidget);
      expect(tester.binding.sendFramesToEngine, isTrue);
      expect(completed, isFalse);

      final timestamp =
          tester.binding.currentSystemFrameTimeStamp.inMicroseconds;
      tester.binding.platformDispatcher.onReportTimings!([
        FrameTiming(
          vsyncStart: timestamp,
          buildStart: timestamp,
          buildFinish: timestamp + 1,
          rasterStart: timestamp + 2,
          rasterFinish: timestamp + 3,
          rasterFinishWallTime: timestamp + 3,
        ),
      ]);
      await tester.pump();
      await handoff;
      expect(completed, isTrue);
    },
  );

  test(
    'Flutter caches the wallpaper before replacing the native backdrop',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ssterm-wallpaper-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/wallpaper.png');
      await file.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l3sAAAAASUVORK5CYII=',
        ),
      );
      final provider = FileImage(file);
      expect(
        PaintingBinding.instance.imageCache.containsKey(provider),
        isFalse,
      );

      await preloadStartupWallpaper(file);

      expect(PaintingBinding.instance.imageCache.containsKey(provider), isTrue);
    },
  );

  test('missing wallpaper does not prevent the Flutter handoff', () async {
    await preloadStartupWallpaper(File('/nonexistent/ssterm-wallpaper.png'));
  });

  test('corrupt wallpaper does not prevent the Flutter handoff', () async {
    final dir = await Directory.systemTemp.createTemp('ssterm-wallpaper-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/wallpaper.png');
    await file.writeAsString('invalid image');

    await expectLater(preloadStartupWallpaper(file), completes);
  });
}
