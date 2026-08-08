import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../io/output_pipe.dart';
import 'local_shell_discovery.dart';

/// Host platform used to decide whether Agent2 can safely start a local,
/// non-terminal shell.  Kept injectable so the policy has deterministic tests.
enum BackgroundCommandPlatform { macos, linux, windows, other }

/// The result of validating a command target before a command is started.
class BackgroundCommandSupport {
  const BackgroundCommandSupport._(this.isSupported, this.reason);

  const BackgroundCommandSupport.supported() : this._(true, null);

  const BackgroundCommandSupport.unsupported(String reason)
    : this._(false, reason);

  final bool isSupported;
  final String? reason;
}

/// A local non-PTY execution target for Agent2.
///
/// This deliberately supports only the shells whose noninteractive semantics
/// we define in v1.  Unsupported targets must remain explicit: falling back to
/// terminal injection would violate Agent2's isolation guarantee.
class BackgroundCommandTarget {
  const BackgroundCommandTarget.local({
    required this.shell,
    required this.cwd,
    required this.platform,
  });

  final LocalShellOption shell;
  final String cwd;
  final BackgroundCommandPlatform platform;

  BackgroundCommandSupport get support {
    if (platform == BackgroundCommandPlatform.windows) {
      return const BackgroundCommandSupport.unsupported(
        'Agent2 background execution is not available on Windows yet.',
      );
    }
    if (platform != BackgroundCommandPlatform.macos &&
        platform != BackgroundCommandPlatform.linux) {
      return const BackgroundCommandSupport.unsupported(
        'Agent2 background execution is supported only on macOS and Linux.',
      );
    }
    if (shell.isWsl || shell.usePowerShellWrapper) {
      return const BackgroundCommandSupport.unsupported(
        'This shell requires a terminal wrapper and cannot run in Agent2.',
      );
    }

    final executable = shell.executable
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase();
    if (executable != 'bash' && executable != 'zsh') {
      return BackgroundCommandSupport.unsupported(
        'Agent2 background execution supports bash and zsh, not '
        '${shell.displayName}.',
      );
    }
    return const BackgroundCommandSupport.supported();
  }

  static BackgroundCommandPlatform get hostPlatform {
    if (Platform.isMacOS) return BackgroundCommandPlatform.macos;
    if (Platform.isLinux) return BackgroundCommandPlatform.linux;
    if (Platform.isWindows) return BackgroundCommandPlatform.windows;
    return BackgroundCommandPlatform.other;
  }
}

/// Runs one supported Agent2 local command outside the visible terminal.
///
/// The executor deliberately uses a normal child process, not a detached
/// process: Agent2 must receive a bounded final result and retain cancellation
/// ownership of the child it started.
class BackgroundCommandExecutor {
  const BackgroundCommandExecutor({
    this.timeout = const Duration(seconds: 120),
    this.outputLimitBytes = 256 * 1024,
  });

  final Duration timeout;
  final int outputLimitBytes;

  Future<CommandResult> executeLocal(
    BackgroundCommandTarget target,
    String command, {
    bool Function()? isCancelled,
  }) async {
    final support = target.support;
    if (!support.isSupported) {
      return CommandResult(
        output: '[ssterm background] ${support.reason}',
        exitCode: null,
      );
    }

    late final Process process;
    try {
      process = await Process.start(
        target.shell.executable,
        ['-c', command],
        workingDirectory: target.cwd,
        runInShell: false,
        includeParentEnvironment: true,
        environment: _nonInteractiveEnvironment(target.shell.environment),
      );
    } on ProcessException catch (error) {
      return CommandResult(
        output:
            '[ssterm background] Could not start ${target.shell.displayName}: $error',
        exitCode: null,
      );
    }

    final stdout = _BoundedOutput(outputLimitBytes);
    final stderr = _BoundedOutput(outputLimitBytes);
    final stdoutDone = process.stdout.listen(stdout.add).asFuture<void>();
    final stderrDone = process.stderr.listen(stderr.add).asFuture<void>();
    final completed = Future.wait<void>([
      process.exitCode.then<void>((_) {}),
      stdoutDone,
      stderrDone,
    ]);

    var cancelled = false;
    final cancellationPoll = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (isCancelled?.call() != true || cancelled) return;
      cancelled = true;
      process.kill(ProcessSignal.sigterm);
      timer.cancel();
    });

    final timedOut = await Future.any<bool>([
      completed.then((_) => false),
      Future<bool>.delayed(timeout, () => true),
    ]);
    if (timedOut) process.kill(ProcessSignal.sigterm);

    // A SIGTERM-resistant direct child still gets a final hard kill. This is
    // intentionally direct-child cleanup only; process-tree containment is a
    // later native-helper enhancement, not a claim made by this v1 executor.
    if (timedOut || cancelled) {
      final stopped = await Future.any<bool>([
        completed.then((_) => true),
        Future<bool>.delayed(const Duration(seconds: 2), () => false),
      ]);
      if (!stopped) process.kill(ProcessSignal.sigkill);
    }
    await completed;
    cancellationPoll.cancel();

    final status = cancelled
        ? 'cancelled'
        : timedOut
        ? 'timed out after ${timeout.inSeconds}s'
        : null;
    return CommandResult(
      output: _formatOutput(stdout, stderr, status),
      exitCode: status == null ? await process.exitCode : null,
      truncated: stdout.truncated || stderr.truncated,
    );
  }

  Map<String, String> _nonInteractiveEnvironment(Map<String, String>? shell) {
    final environment = Map<String, String>.from(Platform.environment);
    if (shell != null) environment.addAll(shell);
    environment.remove('TERM');
    environment.remove('COLORTERM');
    environment.remove('TERM_PROGRAM');
    return environment;
  }

  String _formatOutput(
    _BoundedOutput stdout,
    _BoundedOutput stderr,
    String? status,
  ) {
    final sections = <String>[];
    if (stdout.text.isNotEmpty) sections.add('[stdout]\n${stdout.text}');
    if (stderr.text.isNotEmpty) sections.add('[stderr]\n${stderr.text}');
    if (status != null) sections.add('[ssterm background] $status');
    if (stdout.truncated || stderr.truncated) {
      sections.add('[ssterm background] output truncated');
    }
    return sections.isEmpty ? '' : sections.join('\n');
  }
}

class _BoundedOutput {
  _BoundedOutput(this.limit);

  final int limit;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  bool truncated = false;

  void add(List<int> chunk) {
    final remaining = limit - _bytes.length;
    if (remaining <= 0) {
      truncated = true;
      return;
    }
    if (chunk.length > remaining) {
      _bytes.add(chunk.sublist(0, remaining));
      truncated = true;
      return;
    }
    _bytes.add(chunk);
  }

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}
