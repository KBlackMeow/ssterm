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

  const LocalFileSystemAdapter({this.homeOverride});

  @override
  String get label => 'local';

  @override
  bool get isAvailable => true;

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

  /// Expand a leading `~` to the user's HOME and reject anything that
  /// isn't an absolute path after expansion.  Relative paths are
  /// dangerous in an agent context — the CWD of the Flutter process
  /// is usually `/` (or the app bundle), NOT the terminal's CWD, so a
  /// relative path would land somewhere the user doesn't expect.
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
      throw FileWriteException(
        FileWriteErrorKind.invalidPath,
        'Path must be absolute (start with `/`, `~`, or a drive letter): $p',
      );
    }
    return p;
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

  const SftpFileSystemAdapter({required this.sftp, required this.label});

  @override
  bool get isAvailable => sftp != null;

  @override
  Future<FileWritePreview> preview(String path) async {
    final client = sftp;
    if (client == null) {
      throw const FileWriteException(
        FileWriteErrorKind.notSupported,
        'SSH session is not connected yet.',
      );
    }
    final resolved = _validateRemotePath(path);
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
    final resolved = _validateRemotePath(path);

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

  String _validateRemotePath(String path) {
    final p = path.trim();
    if (p.isEmpty) {
      throw const FileWriteException(
        FileWriteErrorKind.invalidPath,
        'Path is empty.',
      );
    }
    if (!p.startsWith('/')) {
      // Remote `~` is the SSH user's home, but SFTP servers don't
      // universally expand it — `~` resolution is a shell feature, not
      // an SFTP feature.  Refuse it rather than send a path the server
      // would treat as the literal string "~".
      throw FileWriteException(
        FileWriteErrorKind.invalidPath,
        'Remote path must be absolute (start with `/`). '
        'SFTP does not expand `~`; use the full path. Got: $p',
      );
    }
    return p;
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
        'Use an ABSOLUTE path (starting with `/` locally, or full path on a remote). For local writes you may also use `~/…` which expands to the user\'s HOME.',
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
