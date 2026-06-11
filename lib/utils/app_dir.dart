import 'dart:io';

/// Look up an environment variable, treating empty strings as missing.
///
/// Some shells on Windows (Git Bash, Cygwin/MSYS launchers, certain CI
/// runners) set `HOME=""` (empty), which silently breaks the common
/// `Platform.environment['HOME'] ?? fallback` pattern: `??` only fires
/// on `null`, so `"" ?? x` short-circuits to `""`.  When the empty
/// string is then concatenated into `'$home/.ssterm'` you get
/// `'/.ssterm'`, which Windows resolves against the current drive's
/// root — e.g. `C:\.ssterm`, `C:\Downloads`.
String? _envOrNull(String key) {
  final v = Platform.environment[key];
  if (v == null || v.isEmpty) return null;
  return v;
}

/// Best-effort home directory of the current user.
///
/// Returns `null` when nothing usable is available; callers that need
/// a non-null fallback should chain `?? '.'` themselves.
///
/// Windows preference order:
///   1. `USERPROFILE` — set by Windows itself; always points to the
///      right place (`C:\Users\<name>`).
///   2. `HOMEDRIVE` + `HOMEPATH` — official Win32 fallback.
///   3. `HOME` — last resort, since Cygwin/Git-Bash often set it to a
///      Unix-style path (`/c/Users/...` or `/home/<name>`) that Dart's
///      `File`/`Directory` APIs cannot open on Windows.
///
/// POSIX preference order:
///   1. `HOME`
String? userHomeDir() {
  if (Platform.isIOS) {
    // On iOS, HOME is unset.  Derive the app container from the temp
    // dir path: e.g. /var/.../Application/<UUID>/tmp → <UUID>/Documents.
    final tmp = Directory.systemTemp.path;
    final container = tmp.endsWith('/tmp')
        ? tmp.substring(0, tmp.length - 4)
        : Directory.systemTemp.parent.path;
    return '$container/Documents';
  }
  if (Platform.isWindows) {
    return _envOrNull('USERPROFILE') ??
        _composeWindowsHome() ??
        _envOrNull('HOME');
  }
  return _envOrNull('HOME');
}

String? _composeWindowsHome() {
  final drive = _envOrNull('HOMEDRIVE');
  final path = _envOrNull('HOMEPATH');
  if (drive == null || path == null) return null;
  return '$drive$path';
}

/// The base directory under which the app stores its data.  Always
/// non-null; falls back to `.` (current working directory) only when
/// no home can be determined at all — at which point everything is
/// already wrong, but at least we don't crash.
String appBasePath() => userHomeDir() ?? '.';

/// Path of the user's `.ssh` directory.  Forward slashes are fine on
/// Windows — Dart's `File`/`Directory` APIs accept them.
String userSshDir() => '${appBasePath()}/.ssh';

/// Path of the user's standard Downloads folder.  Note this does NOT
/// honour relocated Downloads (Win32 known folder redirection); we
/// avoid `path_provider` to keep dependencies light, and on practical
/// machines this matches the OS-default location.
String userDownloadsDir() => '${appBasePath()}/Downloads';

bool _migrationAttempted = false;

/// The app's writable data directory (`<home>/.ssterm`).
///
/// Triggers a one-shot legacy migration on Windows: pre-fix builds
/// could write `.ssterm` to the current drive's root when `HOME=""`
/// caused the env-resolution to silently produce an empty base path.
/// We move that orphan into the correct location (or aside, if the
/// correct location already has data) on the first call after the
/// fix lands, so users don't lose their saved hosts / known-hosts /
/// settings.
Future<Directory> appDataDir() async {
  final dir = Directory('${appBasePath()}/.ssterm');
  if (!_migrationAttempted) {
    _migrationAttempted = true;
    await _migrateLegacyAppData(dir);
  }
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// One-shot migration for the `HOME=""` bug on Windows.  Best-effort:
/// any failure leaves the orphan in place and returns silently.
Future<void> _migrateLegacyAppData(Directory target) async {
  if (!Platform.isWindows) return;

  // Reproduce the bug's resolution: `'' + '/.ssterm'` resolves to the
  // current drive's root.  We can't recover the drive that was current
  // *at the time of the bad write*, but it's almost certainly the same
  // drive we're running from now.
  final cwd = Directory.current.path;
  if (cwd.length < 2 || cwd[1] != ':') return;
  final driveLetter = cwd[0].toUpperCase();
  final legacy = Directory('$driveLetter:\\.ssterm');

  // Same path as target?  Nothing to do.
  if (_pathsEqualOnWindows(legacy.path, target.path)) return;
  if (!await legacy.exists()) return;

  if (await target.exists()) {
    // Both exist: preserve newer data.  Move the orphan aside so
    // subsequent runs don't see it again, but keep it around in case
    // the user wants to merge by hand.
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    try {
      await legacy.rename('${legacy.path}.legacy-$stamp');
    } catch (_) {/* best-effort */}
  } else {
    // Adopt the orphan as our home.
    try {
      await legacy.rename(target.path);
    } catch (_) {/* best-effort */}
  }
}

bool _pathsEqualOnWindows(String a, String b) {
  String norm(String s) =>
      s.replaceAll('/', '\\').toLowerCase().replaceAll(RegExp(r'\\+$'), '');
  return norm(a) == norm(b);
}
