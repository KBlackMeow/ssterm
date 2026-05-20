import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// struct rlimit { rlim_t rlim_cur; rlim_t rlim_max; }
// rlim_t is 64-bit unsigned on 64-bit macOS/Linux.
final class _Rlimit extends Struct {
  @Uint64()
  external int softLimit;
  @Uint64()
  external int hardLimit;
}

typedef _GetrlimitNative = Int32 Function(Int32, Pointer<_Rlimit>);
typedef _GetrlimitDart = int Function(int, Pointer<_Rlimit>);

typedef _SetrlimitNative = Int32 Function(Int32, Pointer<_Rlimit>);
typedef _SetrlimitDart = int Function(int, Pointer<_Rlimit>);

// RLIMIT_NOFILE: macOS / *BSD = 8, Linux = 7.
int _resourceNoFile() {
  if (Platform.isMacOS || Platform.isIOS) return 8;
  return 7;
}

/// macOS's launchd seeds each process with `RLIMIT_NOFILE = 256`. That is fine
/// for short-lived CLI tools but quickly exhausted by an interactive zsh
/// running plugins such as `zsh-autosuggestions`, `fast-syntax-highlighting`
/// and `zsh-autocomplete` — the shell then prints
/// "too many open files / cannot duplicate fd 0/1" while the user is typing.
///
/// PTY children inherit the parent's rlimits across `posix_spawn`, so we raise
/// the soft limit on the ssterm process once at startup and every spawned
/// shell automatically gets the higher budget. This mirrors what iTerm2,
/// Alacritty, VS Code's integrated terminal and others do.
///
/// Best-effort: no-op on Windows (no POSIX rlimits) and swallows any FFI
/// failure so a hardened sandbox cannot block app startup.
void raiseFileDescriptorLimit({int target = 65535}) {
  if (Platform.isWindows) return;

  try {
    final libc = DynamicLibrary.process();
    final getrlimit =
        libc.lookupFunction<_GetrlimitNative, _GetrlimitDart>('getrlimit');
    final setrlimit =
        libc.lookupFunction<_SetrlimitNative, _SetrlimitDart>('setrlimit');

    final rlim = calloc<_Rlimit>();
    try {
      final resource = _resourceNoFile();
      if (getrlimit(resource, rlim) != 0) return;

      final originalSoft = rlim.ref.softLimit;
      if (originalSoft >= target) return;

      // Some macOS releases cap setrlimit at OPEN_MAX (10240) even when the
      // hard limit reports RLIM_INFINITY. Try the requested target first,
      // then progressively smaller fallbacks so the largest accepted value
      // wins.
      final candidates = <int>{target, 32768, 16384, 10240, 4096}
          .where((c) => c > originalSoft && c <= target)
          .toList()
        ..sort((a, b) => b.compareTo(a));
      for (final c in candidates) {
        rlim.ref.softLimit = c;
        if (setrlimit(resource, rlim) == 0) return;
      }
    } finally {
      calloc.free(rlim);
    }
  } catch (_) {
    // Never fail app launch over a non-critical limit bump.
  }
}
