import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';

/// Decode the saved wallpaper into Flutter's image cache while the desktop
/// window is hidden. The first visible frame can then paint the image itself.
Future<void> preloadStartupWallpaper(File file) async {
  if (!await file.exists()) return;

  final provider = FileImage(file);
  final stream = provider.resolve(ImageConfiguration.empty);
  final ready = Completer<void>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) {
      if (!ready.isCompleted) ready.complete();
    },
    onError: (_, _) {
      // A corrupt or unreadable wallpaper must not strand the hidden window.
      if (!ready.isCompleted) ready.complete();
    },
  );
  stream.addListener(listener);
  try {
    await ready.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  } finally {
    stream.removeListener(listener);
  }
}
