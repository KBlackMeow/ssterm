import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Error categories surfaced by [FileSystemAdapter].  Mapped to a
/// stable user-facing message in [FileWriteService.formatErrorForLlm]
/// so the agent loop doesn't have to re-derive "what went wrong" from
/// an `errno` or a stringly-typed message.
enum FileWriteErrorKind {
  /// Path failed validation (not absolute / forbidden scheme / empty).
  invalidPath,

  /// Target directory does not exist and we declined to mkdir-p
  /// automatically.  The model is told to issue `mkdir -p` via bash
  /// and retry.
  parentMissing,

  /// File already exists and the caller's [expectedMtime] doesn't
  /// match the current on-disk mtime — someone (the user, another
  /// process) edited the file between preview and commit.  We refuse
  /// to overwrite rather than clobber concurrent edits.
  mtimeMismatch,

  /// Permission denied / read-only filesystem / EROFS.  Recoverable
  /// only if the user fixes the perms outside the agent loop.
  permission,

  /// Underlying I/O exception, network failure (SFTP), out-of-space,
  /// or anything else the adapter couldn't classify more precisely.
  io,

  /// Adapter explicitly refuses to handle the request — used by the
  /// SFTP adapter when no SSH session is available, and by the local
  /// adapter when the tab is remote.  Translated into a "use bash
  /// heredoc as a fallback" hint for the model.
  notSupported,
}

class FileWriteException implements Exception {
  final FileWriteErrorKind kind;
  final String message;
  const FileWriteException(this.kind, this.message);

  @override
  String toString() => 'FileWriteException(${kind.name}): $message';
}

/// Result of [FileSystemAdapter.preview] — surfaces just enough state
/// for the chat-card UI to render a meaningful diff preview AND for
/// the commit step to detect concurrent edits.
///
/// We deliberately do NOT load the full existing-file bytes into a
/// String here — for a 100 MB log file we'd spike RAM AND get yelled
/// at by the LLM when the diff doesn't fit context.  Line counts are
/// enough to decide "tiny change vs huge rewrite" at preview time;
/// the user can always inspect via `cat` if they want the byte-exact
/// diff.
class FileWritePreview {
  /// Resolved absolute path (caller's `~` already expanded if local).
  final String resolvedPath;

  /// True when the file already exists.  Drives the UI badge
  /// ("Create" vs "Overwrite") and the mtime check policy.
  final bool exists;

  /// Last-modified timestamp at preview time.  Used by [commit] as a
  /// concurrency token: if the file was edited between preview and
  /// commit, the commit fails with [FileWriteErrorKind.mtimeMismatch]
  /// rather than silently winning the race.  Null when [exists] is
  /// false (no file to time-stamp yet) OR when the adapter cannot
  /// cheaply stat (e.g. some SFTP servers).
  final DateTime? mtime;

  /// Existing-file size in bytes — for UI ("Overwriting a 12 KB file").
  /// Zero for new files.
  final int existingSize;

  /// Existing-file line count, for the chat-card preview.  Capped at
  /// [_lineCountCap] to keep preview cheap on large files.  Null when
  /// the file doesn't exist or the adapter declined to read it.
  final int? existingLines;

  const FileWritePreview({
    required this.resolvedPath,
    required this.exists,
    required this.existingSize,
    this.mtime,
    this.existingLines,
  });
}

class FileWriteResult {
  /// Absolute path actually written to.
  final String resolvedPath;

  /// Bytes the new file ended up holding.
  final int bytesWritten;

  /// New mtime after the commit.  Surfaced in the result envelope so
  /// the model can reference it if it wants to detect "did anything
  /// else touch this file after I wrote it?" in a later turn.
  final DateTime? mtime;

  /// True when the commit created the file, false when it overwrote
  /// an existing one.  UI shows "Created" vs "Updated" accordingly.
  final bool created;

  const FileWriteResult({
    required this.resolvedPath,
    required this.bytesWritten,
    required this.created,
    this.mtime,
  });
}

/// Pluggable backend behind [FileWriteService].  Two implementations
/// today: [LocalFileSystemAdapter] (dart:io on the host running
/// ssterm) and [SftpFileSystemAdapter] (a `dartssh2`-backed SFTP
/// session for the active SSH tab).
///
/// We intentionally don't merge the two into one "smart" adapter —
/// the local path uses Dart File APIs (atomic via temp+rename), the
/// SFTP path uses the dartssh2 [SftpClient].  Keeping them separate
/// makes the test surface narrow (mock one without standing up the
/// other) and lets future adapters (S3, Docker volume, etc.) slot in
/// without re-touching the existing two.
abstract class FileSystemAdapter {
  /// Human-readable adapter name surfaced in chat-card subtitles
  /// ("local" / "ssh: prod-db").  NOT exposed to the LLM — model only
  /// sees the result envelope.
  String get label;

  /// True when this adapter is connected and ready to serve writes.
  /// The agent panel checks this before showing the "Apply" button so
  /// a disconnected SSH tab fails fast at preview time, not after the
  /// user clicks Apply.
  bool get isAvailable;

  /// Best-effort current working directory used to resolve relative
  /// paths AND `~/…` expansions.  Null when unknown; in that case the
  /// adapter falls back to its "absolute paths only" policy.
  ///
  /// LOCAL adapter: the active terminal pane's PWD (via OSC 7) when
  /// known, else the host process HOME, else null.
  /// SFTP  adapter: the active SSH pane's PWD (via OSC 7) when known.
  ///
  /// Exposed for [AiAssistantOverlay] so it can advertise the working
  /// directory to the LLM in a `<session_context>` block — telling the
  /// model the PWD upfront avoids the "I'll just guess `~/foo.sh`"
  /// failure mode that the SFTP adapter rejected before this hook
  /// existed.
  String? get currentDirectory;

  /// Best-effort HOME directory for `~/…` expansion.  Local adapter
  /// returns the host's HOME; SFTP adapter returns the directory the
  /// SFTP channel landed in (which is the user's HOME on the vast
  /// majority of servers — chroot SFTP setups being the exception).
  ///
  /// Returns null when no probe has succeeded yet; the model is told
  /// to use absolute paths in that case.
  Future<String?> homeDirectory();

  /// Inspect the target path WITHOUT modifying anything.  Returns
  /// [FileWritePreview] on success; throws [FileWriteException] for
  /// the validation-class errors ([FileWriteErrorKind.invalidPath],
  /// [FileWriteErrorKind.notSupported]) that the UI must surface
  /// before showing an Apply button.
  Future<FileWritePreview> preview(String path);

  /// Atomically write [content] to [path].  When [expectedMtime] is
  /// supplied and the on-disk mtime differs at commit time, the write
  /// is aborted with [FileWriteErrorKind.mtimeMismatch] — protects
  /// against silently clobbering concurrent edits.
  ///
  /// Adapters MUST guarantee at-least atomicity at the filename level:
  /// either the file ends up with the full new contents OR it stays
  /// untouched.  Half-written tail bytes are NEVER acceptable.
  Future<FileWriteResult> commit(
    String path,
    String content, {
    DateTime? expectedMtime,
  });
}

/// dart:io-backed adapter.  Used for LOCAL terminal tabs.  Atomic
/// write strategy: write to `<path>.ssterm-tmp-<rand>` in the same
/// directory, fsync, then rename over [path].  Same-directory rename
/// is the only way to get a POSIX-atomic replace on most filesystems
/// (cross-fs rename falls back to copy+unlink which IS NOT atomic).
class LocalFileSystemAdapter implements FileSystemAdapter {
  /// Allow tests to point the adapter at a fixture-controlled HOME
  /// without touching the real one.  Production code leaves null.
  final String? homeOverride;

  /// Snapshot supplier for the active terminal pane's PWD.  Called on
  /// every preview / commit so a `cd` issued between operations is
  /// reflected immediately, without the host needing to rebuild the
  /// adapter on each OSC 7 update.
  ///
  /// Returning null means "PWD unknown" — relative paths then fall
  /// back to the existing `invalidPath` error.
  final String? Function()? cwdProvider;

  const LocalFileSystemAdapter({this.homeOverride, this.cwdProvider});

  @override
  String get label => 'local';

  @override
  bool get isAvailable => true;

  @override
  String? get currentDirectory =>
      cwdProvider?.call() ??
      homeOverride ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];

  @override
  Future<String?> homeDirectory() async =>
      homeOverride ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];

  @override
  Future<FileWritePreview> preview(String path) async {
    final resolved = _resolvePath(path);
    final f = File(resolved);
    if (!await f.exists()) {
      // Surface "parent missing" as a distinct kind so the LLM gets a
      // crisp "mkdir -p first" hint instead of a generic I/O error.
      final dir = Directory(_dirname(resolved));
      if (!await dir.exists()) {
        throw FileWriteException(
          FileWriteErrorKind.parentMissing,
          'Parent directory does not exist: ${dir.path}',
        );
      }
      return FileWritePreview(
        resolvedPath: resolved,
        exists: false,
        existingSize: 0,
      );
    }
    final stat = await f.stat();
    int? lines;
    try {
      // Only count lines for "small enough" files — readAsLines on a
      // 1 GB log file would OOM.  4 MB threshold matches editors'
      // default "open as text" cutoff.
      if (stat.size <= 4 * 1024 * 1024) {
        lines = (await f.readAsLines()).length;
      }
    } catch (_) {
      // Binary content / decode failure → leave lines null, UI shows "—".
    }
    return FileWritePreview(
      resolvedPath: resolved,
      exists: true,
      mtime: stat.modified,
      existingSize: stat.size,
      existingLines: lines,
    );
  }

  @override
  Future<FileWriteResult> commit(
    String path,
    String content, {
    DateTime? expectedMtime,
  }) async {
    final resolved = _resolvePath(path);
    final f = File(resolved);
    final existed = await f.exists();
    if (existed && expectedMtime != null) {
      final cur = (await f.stat()).modified;
      // dart:io's mtime granularity is platform-defined (typically
      // ~ms on macOS/Linux).  Compare with a 1s slop so a "no-op
      // touch" between preview and commit (timer scheduler, antivirus
      // scan) doesn't trip the mismatch guard.
      if (cur.difference(expectedMtime).abs() > const Duration(seconds: 1)) {
        throw FileWriteException(
          FileWriteErrorKind.mtimeMismatch,
          'File was modified after preview: '
          'preview=${expectedMtime.toIso8601String()} '
          'current=${cur.toIso8601String()}',
        );
      }
    }
    final dir = Directory(_dirname(resolved));
    if (!await dir.exists()) {
      throw FileWriteException(
        FileWriteErrorKind.parentMissing,
        'Parent directory does not exist: ${dir.path}',
      );
    }
    // Suffix randomness: timestamp + microsecond + isolate hash gives
    // collision-safe naming without depending on `package:uuid`.
    final tmp = File('$resolved.ssterm-tmp-'
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${identityHashCode(this)}');
    try {
      // writeAsString already fsync-ish on dart:io for the file body;
      // rename() then makes the swap atomic at the directory level
      // (provided we stayed in the same FS — guaranteed by placing
      // the tmp next to the target).
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(resolved);
    } on FileSystemException catch (e) {
      // Cleanup: a half-baked tmp must not be left behind, otherwise
      // repeated failed writes pile up next to the target.  Best-effort.
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      // Map common POSIX errnos to our coarser kinds.
      final code = e.osError?.errorCode;
      if (code == 13 || code == 1) {
        throw FileWriteException(
          FileWriteErrorKind.permission,
          'Permission denied: ${e.message}',
        );
      }
      throw FileWriteException(
        FileWriteErrorKind.io,
        'Write failed: ${e.message}',
      );
    }
    final stat = await File(resolved).stat();
    return FileWriteResult(
      resolvedPath: resolved,
      bytesWritten: utf8.encode(content).length,
      mtime: stat.modified,
      created: !existed,
    );
  }

  /// Expand a leading `~` to the user's HOME, join relative paths to
  /// the active terminal pane's PWD (when [cwdProvider] supplies one),
  /// and reject everything else.
  ///
  /// Relative paths used to be a hard error here: the Flutter process
  /// CWD is usually `/` (or the .app bundle), NOT the terminal's PWD,
  /// so any resolution against `Directory.current` would land the
  /// file somewhere the user doesn't expect.  Now we ALSO accept
  /// relatives WHEN we know the terminal's PWD (OSC 7 reported it),
  /// because then the resolution matches what the user sees in their
  /// shell — same semantics as if they'd typed the path into bash.
  String _resolvePath(String input) {
    var p = input.trim();
    if (p.isEmpty) {
      throw const FileWriteException(
        FileWriteErrorKind.invalidPath,
        'Path is empty.',
      );
    }
    if (p == '~' || p.startsWith('~/')) {
      final home = homeOverride ??
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isEmpty) {
        throw const FileWriteException(
          FileWriteErrorKind.invalidPath,
          'Cannot expand ~ — no HOME environment variable.',
        );
      }
      p = p == '~' ? home : '$home${p.substring(1)}';
    }
    if (!p.startsWith('/') && !_isWindowsAbsolute(p)) {
      // Try resolving against the terminal pane's PWD.  We only do
      // this when the host supplied a `cwdProvider` AND it returns a
      // non-empty value — falling back to `Directory.current` would
      // resolve to the .app bundle on macOS, which is never what the
      // user wants.
      final cwd = cwdProvider?.call();
      if (cwd != null && cwd.isNotEmpty &&
          (cwd.startsWith('/') || _isWindowsAbsolute(cwd))) {
        p = _joinPath(cwd, p);
      } else {
        throw FileWriteException(
          FileWriteErrorKind.invalidPath,
          cwd == null || cwd.isEmpty
              ? 'Path must be absolute (start with `/`, `~`, or a '
                  'drive letter): $p\n'
                  '(Terminal PWD is not known yet — type a command in '
                  'the shell so OSC 7 reports it, then retry.)'
              : 'Path must be absolute (start with `/`, `~`, or a '
                  'drive letter): $p',
        );
      }
    }
    return p;
  }

  /// Join `base` and `rel` with exactly one separator between them.
  /// `rel` is assumed already-trimmed and non-absolute.
  String _joinPath(String base, String rel) {
    if (base.endsWith('/') || base.endsWith(r'\')) return '$base$rel';
    return '$base/$rel';
  }

  bool _isWindowsAbsolute(String p) {
    // `C:\` / `D:\` style — accept both forward and backslash separators.
    if (p.length < 3) return false;
    final c = p.codeUnitAt(0);
    final isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    return isLetter &&
        p.codeUnitAt(1) == 0x3A /* : */ &&
        (p.codeUnitAt(2) == 0x2F /* / */ || p.codeUnitAt(2) == 0x5C /* \\ */);
  }

  String _dirname(String p) {
    final i = p.lastIndexOf('/');
    if (i < 0) return '.';
    if (i == 0) return '/';
    return p.substring(0, i);
  }
}

/// `dartssh2`-backed SFTP adapter.  Used for SSH terminal tabs that
/// already have a connected [SftpClient] (every healthy SSH tab does
/// — see `tab.sftp` in TabModel).  The adapter does NOT manage the
/// session itself: the caller owns it, we just borrow the channel.
///
/// Atomicity: SFTP doesn't expose an atomic-rename primitive on every
/// server, but `posix-rename` is part of OpenSSH's `posix-rename@…`
/// extension and dartssh2's `rename` falls back to a plain rename
/// when that extension is absent.  Either is "atomic enough" for our
/// purposes (we never get a half-written tail bytes view, and any
/// reader will see either the OLD inode or the NEW one).
class SftpFileSystemAdapter implements FileSystemAdapter {
  /// The SFTP client bound to the active SSH tab.  Null when the tab
  /// hasn't completed its SSH handshake yet — in that case
  /// [isAvailable] is false and the agent loop tells the model to
  /// retry once the connection comes up.
  final SftpClient? sftp;

  /// Display label for the chat card subtitle ("ssh: prod-db").
  /// Pass the user-friendly tab title here.
  @override
  final String label;

  /// Snapshot supplier for the active SSH pane's PWD (typically
  /// surfaced via the `__ssterm_cwd` shell hook → OSC 7 → the host's
  /// `tab.remoteCwdPane*` field).  Called on every preview / commit
  /// so a `cd` issued mid-conversation is reflected immediately,
  /// without the host needing to rebuild the adapter on each
  /// OSC 7 update.
  ///
  /// Returning null means "remote PWD unknown" — the model is then
  /// told to use an absolute path in the error envelope, INCLUDING
  /// the SFTP HOME we discovered so it has a concrete starting point.
  final String? Function()? cwdProvider;

  SftpFileSystemAdapter({
    required this.sftp,
    required this.label,
    this.cwdProvider,
  });

  /// Lazily-discovered HOME on the remote — populated by the first
  /// call to [homeDirectory] and reused thereafter.  Cached because
  /// `SSH_FXP_REALPATH` is a network round-trip; we want it once per
  /// adapter, not once per write.
  ///
  /// Why this works: the SFTP server lands the channel in the SSH
  /// user's HOME by default, so `realpath('.')` returns HOME on the
  /// vast majority of servers (chroot SFTP setups being the lone
  /// exception, and they typically use a fixed root anyway).
  String? _cachedHome;

  @override
  bool get isAvailable => sftp != null;

  @override
  String? get currentDirectory => cwdProvider?.call() ?? _cachedHome;

  @override
  Future<String?> homeDirectory() async {
    if (_cachedHome != null) return _cachedHome;
    final client = sftp;
    if (client == null) return null;
    try {
      _cachedHome = await client.absolute('.');
    } catch (_) {
      _cachedHome = null;
    }
    return _cachedHome;
  }

  @override
  Future<FileWritePreview> preview(String path) async {
    final client = sftp;
    if (client == null) {
      throw const FileWriteException(
        FileWriteErrorKind.notSupported,
        'SSH session is not connected yet.',
      );
    }
    final resolved = await _resolveRemotePath(path);
    SftpFileAttrs? attrs;
    try {
      attrs = await client.stat(resolved);
    } on SftpStatusError catch (e) {
      // SSH_FX_NO_SUCH_FILE = 2; anything else surfaces as I/O.
      if (e.code == 2) {
        attrs = null;
      } else {
        throw FileWriteException(
          FileWriteErrorKind.io,
          'SFTP stat failed: ${e.message}',
        );
      }
    }
    if (attrs == null) {
      // Confirm parent exists — same crisp UX as the local adapter.
      final parent = _dirname(resolved);
      try {
        await client.stat(parent);
      } on SftpStatusError catch (e) {
        if (e.code == 2) {
          throw FileWriteException(
            FileWriteErrorKind.parentMissing,
            'Parent directory does not exist on the remote: $parent',
          );
        }
      }
      return FileWritePreview(
        resolvedPath: resolved,
        exists: false,
        existingSize: 0,
      );
    }
    // Existing file — pull a line count for the preview, capped at 4 MB
    // so a remote 1 GB log doesn't choke the channel.
    final size = attrs.size ?? 0;
    int? lines;
    if (size > 0 && size <= 4 * 1024 * 1024) {
      try {
        final remote = await client.open(resolved);
        try {
          final bytes = await remote.readBytes();
          lines = const LineSplitter().convert(utf8.decode(bytes)).length;
        } finally {
          await remote.close();
        }
      } catch (_) {
        // Binary / decode failure → leave lines null.
      }
    }
    final mtime = attrs.modifyTime == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000);
    return FileWritePreview(
      resolvedPath: resolved,
      exists: true,
      mtime: mtime,
      existingSize: size,
      existingLines: lines,
    );
  }

  @override
  Future<FileWriteResult> commit(
    String path,
    String content, {
    DateTime? expectedMtime,
  }) async {
    final client = sftp;
    if (client == null) {
      throw const FileWriteException(
        FileWriteErrorKind.notSupported,
        'SSH session is not connected yet.',
      );
    }
    final resolved = await _resolveRemotePath(path);

    // mtime concurrency check — same semantics as the local adapter
    // (1s slop to absorb mtime granularity differences).
    bool existed = true;
    try {
      final cur = await client.stat(resolved);
      if (expectedMtime != null && cur.modifyTime != null) {
        final curDt = DateTime.fromMillisecondsSinceEpoch(
            cur.modifyTime! * 1000);
        if (curDt.difference(expectedMtime).abs() >
            const Duration(seconds: 1)) {
          throw FileWriteException(
            FileWriteErrorKind.mtimeMismatch,
            'Remote file was modified after preview: '
            'preview=${expectedMtime.toIso8601String()} '
            'current=${curDt.toIso8601String()}',
          );
        }
      }
    } on SftpStatusError catch (e) {
      if (e.code == 2) {
        existed = false;
      } else {
        throw FileWriteException(
          FileWriteErrorKind.io,
          'SFTP stat failed: ${e.message}',
        );
      }
    }

    // Write to a sibling temp path and rename onto the target — same
    // atomicity recipe as the local adapter, just using SFTP ops.
    final tmpPath = '$resolved.ssterm-tmp-'
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${identityHashCode(this)}';
    try {
      final remote = await client.open(
        tmpPath,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        final bytes = Uint8List.fromList(utf8.encode(content));
        // dartssh2 expects a stream of Uint8List for `write`.  One-shot
        // for now — splitting is only worth it for huge bodies (>1 MB),
        // which we don't realistically generate with an LLM marker.
        final writer = remote.write(Stream<Uint8List>.value(bytes));
        await writer.done;
      } finally {
        await remote.close();
      }
      // dartssh2 SftpClient.rename does posix-rename when the server
      // advertises the extension, otherwise a plain rename.  Either
      // way it's atomic at the directory entry level.
      if (existed) {
        // Some servers refuse rename-over-existing; remove the target
        // first as a fallback path.  We accept the brief "no file"
        // window because it's still better than the half-written-tail
        // window the bash heredoc path leaves.
        try {
          await client.rename(tmpPath, resolved);
        } on SftpStatusError {
          await client.remove(resolved);
          await client.rename(tmpPath, resolved);
        }
      } else {
        await client.rename(tmpPath, resolved);
      }
    } catch (e) {
      // Best-effort tmp cleanup before bubbling up.
      try {
        await client.remove(tmpPath);
      } catch (_) {}
      if (e is FileWriteException) rethrow;
      throw FileWriteException(
        FileWriteErrorKind.io,
        'SFTP write failed: $e',
      );
    }

    DateTime? mtime;
    try {
      final stat = await client.stat(resolved);
      if (stat.modifyTime != null) {
        mtime = DateTime.fromMillisecondsSinceEpoch(stat.modifyTime! * 1000);
      }
    } catch (_) {
      // Non-fatal: post-commit stat failed but the bytes are on disk.
    }
    return FileWriteResult(
      resolvedPath: resolved,
      bytesWritten: utf8.encode(content).length,
      mtime: mtime,
      created: !existed,
    );
  }

  /// Resolve a model-emitted path to an absolute POSIX-style path the
  /// SFTP server will accept.  Handles three input shapes:
  ///
  ///   • Absolute (`/etc/hosts`)         → returned as-is.
  ///   • Tilde   (`~`, `~/foo`)          → expanded via [homeDirectory]
  ///     (lazily discovered with `SSH_FXP_REALPATH('.')` and cached).
  ///   • Relative (`foo`, `./foo`, `a/b`) → joined to the SSH pane's
  ///     PWD when [cwdProvider] supplies one; falls back to HOME if
  ///     PWD is unknown but HOME was discovered (best-effort — better
  ///     than refusing).  When neither is available, throws
  ///     `invalidPath` with a helpful message naming the discovered
  ///     HOME (if any) so the model has a concrete absolute path to
  ///     retry with.
  ///
  /// We deliberately do NOT delegate to `client.absolute(p)` for
  /// relative paths — that returns the CHANNEL's CWD which on most
  /// servers is HOME, not the shell's PWD.  Using the shell's PWD
  /// matches what `cat > foo` would do in the same terminal pane.
  Future<String> _resolveRemotePath(String path) async {
    final p = path.trim();
    if (p.isEmpty) {
      throw const FileWriteException(
        FileWriteErrorKind.invalidPath,
        'Path is empty.',
      );
    }
    if (p.startsWith('/')) return p;

    if (p == '~' || p.startsWith('~/')) {
      final home = await homeDirectory();
      if (home == null || home.isEmpty) {
        throw const FileWriteException(
          FileWriteErrorKind.invalidPath,
          'Remote `~` cannot be expanded — SFTP HOME probe '
          '(realpath \'.\') failed. Use an absolute path like '
          '`/home/<user>/<file>` instead.',
        );
      }
      return p == '~' ? home : _joinPath(home, p.substring(2));
    }

    // Strip an optional `./` prefix — `./foo` is the same as `foo`.
    final rel = p.startsWith('./') ? p.substring(2) : p;

    final cwd = cwdProvider?.call();
    if (cwd != null && cwd.isNotEmpty && cwd.startsWith('/')) {
      return _joinPath(cwd, rel);
    }

    // No cwd reported via OSC 7 yet — fall back to HOME (the
    // user's working dir at connect time, equivalent to the very
    // first PWD a fresh shell sees).  Better than refusing AND
    // accidentally lands close to the right place on a brand-new
    // session.
    final home = await homeDirectory();
    if (home != null && home.isNotEmpty) {
      return _joinPath(home, rel);
    }

    throw FileWriteException(
      FileWriteErrorKind.invalidPath,
      'Remote path is relative but the SSH PWD is not known yet '
      '(no OSC 7 update received, and SFTP HOME probe failed). '
      'Use an absolute path starting with `/`. Got: $p',
    );
  }

  /// Join `base` and `rel` with exactly one `/` between them.
  /// `rel` is assumed already-trimmed and non-absolute.
  String _joinPath(String base, String rel) {
    if (base.endsWith('/')) return '$base$rel';
    return '$base/$rel';
  }

  String _dirname(String p) {
    final i = p.lastIndexOf('/');
    if (i < 0) return '.';
    if (i == 0) return '/';
    return p.substring(0, i);
  }
}

/// Stateless helpers used by both the panel UI and tests.
class FileWriteService {
  /// Format a successful write into the user-role message we inject
  /// after the user clicks Apply.  Mirrors the `[Command executed]` /
  /// `[Web search results]` envelope shape so the model treats it as
  /// "tool output" uniformly.
  static String formatSuccessForLlm(FileWriteResult r) {
    final created = r.created ? 'true' : 'false';
    final mtime = r.mtime?.toIso8601String() ?? '-';
    return '[File written]\n'
        'path: ${r.resolvedPath}\n'
        'bytes: ${r.bytesWritten}\n'
        'created: $created\n'
        'mtime: $mtime';
  }

  /// Format a write proposal that the USER REJECTED via the chat-card
  /// "Reject" button.  Includes a short reason if the user typed one;
  /// the recovery hint tells the model not to retry blindly.
  static String formatRejectionForLlm(String path, {String? reason}) {
    final why = reason == null || reason.trim().isEmpty
        ? '(no reason given)'
        : reason.trim();
    return '[File write rejected by user]\n'
        'path: $path\n'
        'reason: $why\n\n'
        'The user declined this write. Do NOT re-emit the same '
        '[WRITE_FILE_BEGIN] for the same path. Either ask the user '
        'what to change, propose a different path, or proceed without '
        'the write.';
  }

  /// Format a [FileWriteException] caught during preview or commit
  /// into the rejection envelope.  Maps each error kind to a stable
  /// recovery hint so the model's next turn behaves correctly.
  static String formatErrorForLlm(String path, FileWriteException e) {
    final recovery = switch (e.kind) {
      FileWriteErrorKind.invalidPath =>
        'Path resolution failed. Prefer an ABSOLUTE path (starting with `/`). `~/…` works on BOTH local and SSH tabs (ssterm expands it for you over SFTP). Relative paths resolve against the active terminal pane\'s PWD only when OSC 7 has reported one — the upstream `message` above says whether the PWD was known. When unsure, reuse the absolute PWD or HOME shown in the `<session_context>` block from earlier in this conversation.',
      FileWriteErrorKind.parentMissing =>
        'Run `mkdir -p <parent>` via bash FIRST, then retry [WRITE_FILE_BEGIN].',
      FileWriteErrorKind.mtimeMismatch =>
        'The file changed under you. Re-read it with `cat` to see the current contents, then issue a NEW [WRITE_FILE_BEGIN] reflecting that state.',
      FileWriteErrorKind.permission =>
        'Permission denied. Tell the user the path needs to be writable (or `sudo`-owned) — do NOT retry with the same path until they confirm.',
      FileWriteErrorKind.io =>
        'I/O failed. You may retry ONCE; if it fails again, fall back to `cat <<EOF > path` via bash.',
      FileWriteErrorKind.notSupported =>
        'This adapter cannot handle the write (the SSH session may not be ready, or the path scheme is unsupported). Fall back to `cat <<EOF > path` via bash.',
    };
    return '[File write failed]\n'
        'path: $path\n'
        'reason: ${e.kind.name}\n'
        'message: ${e.message}\n\n'
        '$recovery';
  }
}
