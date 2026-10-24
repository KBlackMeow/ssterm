import 'dart:async';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/widgets.dart';

import '../models/terminal_settings.dart';

/// The native wallpaper already includes the terminal's background shade.
/// Keep Flutter's surfaces clear until its own wallpaper replaces that image,
/// otherwise the shade would be applied twice during the handoff.
TerminalSettings terminalSettingsForBackdrop(
  TerminalSettings settings, {
  required bool nativeWallpaperVisible,
}) =>
    nativeWallpaperVisible ? settings.copyWith(backgroundOpacity: 0) : settings;

/// Warm Flutter's wallpaper cache while the native window shows the same file.
/// The terminal can build and start its shell while this decode is in flight.
Future<void> preloadStartupWallpaper(File file) async {
  if (!await file.exists()) return;

  final stream = FileImage(file).resolve(ImageConfiguration.empty);
  final ready = Completer<void>();
  final listener = ImageStreamListener(
    (_, _) {
      if (!ready.isCompleted) ready.complete();
    },
    onError: (_, _) {
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

/// Wait for a new painted frame, without withholding any earlier terminal UI.
/// The image stream has updated its widgets before this callback is scheduled.
Future<void> waitForStartupWallpaperFrame(WidgetsBinding binding) async {
  final rasterized = Completer<void>();
  int? targetVsync;
  void onTimings(List<FrameTiming> timings) {
    final target = targetVsync;
    if (target != null &&
        timings.any(
          (frame) =>
              frame.timestampInMicroseconds(FramePhase.vsyncStart) >= target,
        ) &&
        !rasterized.isCompleted) {
      rasterized.complete();
    }
  }

  binding.addTimingsCallback(onTimings);
  binding.addPostFrameCallback((_) {
    targetVsync = binding.currentSystemFrameTimeStamp.inMicroseconds;
  });
  binding.scheduleFrame();
  try {
    await rasterized.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
  } finally {
    binding.removeTimingsCallback(onTimings);
  }
}
