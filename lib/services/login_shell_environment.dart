import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'local_shell_discovery.dart';

typedef LoginShellPathReader = Future<String?> Function(LocalShellOption shell);

/// Reads the exported PATH of a user's login shell once per shell executable.
///
/// This intentionally captures no other environment variables, aliases, or
/// functions. The cached result remains in memory only.
class LoginShellEnvironmentResolver {
  LoginShellEnvironmentResolver({
    LoginShellPathReader? readPath,
    this.timeout = const Duration(seconds: 3),
    this.outputLimitBytes = 32 * 1024,
  }) : _readPath = readPath;

  final LoginShellPathReader? _readPath;
  final Duration timeout;
  final int outputLimitBytes;
  final Map<String, Future<Map<String, String>>> _cache = {};

  Future<Map<String, String>> resolvePath(LocalShellOption shell) =>
      _cache.putIfAbsent(shell.executable, () => _resolve(shell));

  Future<Map<String, String>> _resolve(LocalShellOption shell) async {
    try {
      final path =
          await (_readPath?.call(shell) ?? _readPathFromLoginShell(shell));
      if (path == null || path.isEmpty || path.contains('\u0000')) {
        return const {};
      }
      return {'PATH': path};
    } catch (_) {
      return const {};
    }
  }

  Future<String?> _readPathFromLoginShell(LocalShellOption shell) async {
    late final Process process;
    try {
      process = await Process.start(shell.executable, const [
        '-l',
        '-c',
        r'printf "%s\0" "$PATH"',
      ], runInShell: false);
    } on ProcessException {
      return null;
    }

    final stdout = _BoundedBytes(outputLimitBytes);
    final stdoutDone = process.stdout.listen(stdout.add).asFuture<void>();
    final stderrDone = process.stderr.drain<void>();
    final finished = Future.wait<void>([
      process.exitCode.then<void>((_) {}),
      stdoutDone,
      stderrDone,
    ]);
    try {
      await finished.timeout(timeout);
    } on TimeoutException {
      process.kill();
      await Future.any<void>([
        finished.catchError((_) {}),
        Future<void>.delayed(const Duration(seconds: 1)),
      ]);
      return null;
    }
    if (await process.exitCode != 0 || stdout.truncated) return null;

    final output = utf8.decode(stdout.bytes, allowMalformed: false);
    final terminator = output.indexOf('\u0000');
    if (terminator < 1 || terminator != output.length - 1) return null;
    return output.substring(0, terminator);
  }
}

class _BoundedBytes {
  _BoundedBytes(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool truncated = false;

  List<int> get bytes => _builder.toBytes();

  void add(List<int> chunk) {
    final remaining = limit - _builder.length;
    if (remaining <= 0) {
      truncated = true;
      return;
    }
    if (chunk.length > remaining) {
      _builder.add(chunk.take(remaining).toList(growable: false));
      truncated = true;
      return;
    }
    _builder.add(chunk);
  }
}
