import 'package:flutter/foundation.dart';

import 'platform.dart';

/// Maps the host Flutter platform to [TerminalTargetPlatform] for key bindings.
TerminalTargetPlatform detectTerminalHostPlatform() {
  if (kIsWeb) {
    return TerminalTargetPlatform.web;
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return TerminalTargetPlatform.android;
    case TargetPlatform.iOS:
      return TerminalTargetPlatform.ios;
    case TargetPlatform.fuchsia:
      return TerminalTargetPlatform.fuchsia;
    case TargetPlatform.linux:
      return TerminalTargetPlatform.linux;
    case TargetPlatform.macOS:
      return TerminalTargetPlatform.macos;
    case TargetPlatform.windows:
      return TerminalTargetPlatform.windows;
  }
}
