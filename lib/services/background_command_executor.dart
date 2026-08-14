import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import '../io/output_pipe.dart';
import 'command_safety.dart';
import 'login_shell_environment.dart';
import 'local_shell_discovery.dart';

const _maxCwdResultBytes = 16 * 1024;

/// Incremental background-command output suitable for a live Agent card.
class CommandExecutionUpdate {
  const CommandExecutionUpdate(this.lastThreeLines);

  final List<String> lastThreeLines;
}

typedef CommandExecutionUpdateListener = void Function(
  CommandExecutionUpdate update,
);

typedef BackgroundProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
      bool runInShell,
    });

typedef BackgroundSshSessionStarter =
    Future<SSHSession> Function(SSHClient client, String command);

typedef BackgroundSshCwdResultReader =
    Future<List<int>?> Function(SSHClient client, String resultPath);

Future<SSHSession> _startSshSession(SSHClient client, String command) =>
    client.execute(command);

/// Host platform used to decide whether Agent can safely start a local,
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

/// A local non-PTY execution target for Agent.
///
/// This deliberately supports only the shells whose noninteractive semantics
/// we define in v1.  Unsupported targets must remain explicit: falling back to
/// the interactive terminal would violate Agent's isolation guarantee.
class BackgroundCommandTarget {
  const BackgroundCommandTarget.local({
    required this.shell,
    required this.cwd,
    required this.platform,
  });

  final LocalShellOption shell;
  final String cwd;
  final BackgroundCommandPlatform platform;

  String? get processWorkingDirectory =>
      shell.isWsl ? null : nativePathForLocalShell(shell, cwd);

  BackgroundCommandSupport get support {
    if (platform == BackgroundCommandPlatform.windows) {
      if (shell.id == 'cmd' ||
          shell.usePowerShellCwdWrapper ||
          shell.isWsl ||
          shell.id.startsWith('git-bash') ||
          shell.executable.toLowerCase().endsWith('bash.exe')) {
        return const BackgroundCommandSupport.supported();
      }
      return const BackgroundCommandSupport.unsupported(
        'Agent background execution does not support this Windows shell.',
      );
    }
    if (platform != BackgroundCommandPlatform.macos &&
        platform != BackgroundCommandPlatform.linux) {
      return const BackgroundCommandSupport.unsupported(
        'Agent background execution is supported only on macOS and Linux.',
      );
    }
    if (shell.isWsl || shell.usePowerShellCwdWrapper) {
      return const BackgroundCommandSupport.unsupported(
        'This shell requires a terminal wrapper and cannot run in Agent.',
      );
    }

    final executable = shell.executable
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase();
    if (executable != 'bash' && executable != 'zsh') {
      return BackgroundCommandSupport.unsupported(
        'Agent background execution supports bash and zsh, not '
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

/// Runs one supported Agent local command outside the visible terminal.
///
/// The executor deliberately uses a normal child process, not a detached
/// process: Agent must receive a bounded final result and retain cancellation
/// ownership of the child it started.
class BackgroundCommandExecutor {
  const BackgroundCommandExecutor({
    this.timeout = const Duration(seconds: 120),
    this.silenceTimeout = const Duration(seconds: 60),
    this.outputLimitBytes = 256 * 1024,
    this.loginEnvironmentResolver,
    this.processStarter,
    this.sshSessionStarter,
    this.sshCwdResultReader,
  });

  final Duration timeout;
  /// Stops a command which has made no observable progress for this interval.
  final Duration silenceTimeout;
  final int outputLimitBytes;
  final LoginShellEnvironmentResolver? loginEnvironmentResolver;
  final BackgroundProcessStarter? processStarter;
  final BackgroundSshSessionStarter? sshSessionStarter;
  final BackgroundSshCwdResultReader? sshCwdResultReader;

  static final _defaultLoginEnvironmentResolver =
      LoginShellEnvironmentResolver();

  Future<CommandResult> executeLocal(
    BackgroundCommandTarget target,
    String command, {
    bool Function()? isCancelled,
    CommandExecutionUpdateListener? onUpdate,
  }) async {
    final safetyReason = CommandSafety.reason(command);
    if (safetyReason != null) {
      return CommandResult(
        output: '[ssterm safety check] $safetyReason',
        exitCode: null,
      );
    }
    final support = target.support;
    if (!support.isSupported) {
      return CommandResult(
        output: '[ssterm background] ${support.reason}',
        exitCode: null,
      );
    }
    final syntaxIssue = validateBackgroundCommandSyntax(target, command);
    if (syntaxIssue != null) {
      return CommandResult(
        output: '[ssterm background] $syntaxIssue',
        exitCode: null,
      );
    }
    if (isCancelled?.call() == true) {
      return CommandResult(
        output: '[ssterm background] cancelled',
        exitCode: null,
        cancelled: true,
      );
    }

    final wslMarker = target.shell.isWsl ? _wslMarkerPath() : null;
    final posixMarker =
        target.platform == BackgroundCommandPlatform.macos ||
            target.platform == BackgroundCommandPlatform.linux
        ? _posixMarkerPath()
        : null;
    final environment = _nonInteractiveEnvironment(target.shell.environment);
    if (target.platform == BackgroundCommandPlatform.macos ||
        target.platform == BackgroundCommandPlatform.linux) {
      final loginEnvironment =
          await (loginEnvironmentResolver ?? _defaultLoginEnvironmentResolver)
              .resolvePath(target.shell);
      if (isCancelled?.call() == true) {
        return CommandResult(
          output: '[ssterm background] cancelled',
          exitCode: null,
          cancelled: true,
        );
      }
      environment.addAll(loginEnvironment);
    }
    final cwdResultDirectory = await Directory.systemTemp.createTemp(
      'ssterm-agent-cwd-',
    );
    final cwdResultPath = '${cwdResultDirectory.path}/result';
    try {
      late final Process process;
      try {
        final invocation = buildBackgroundCommandInvocation(
          target,
          command,
          wslProcessMarker: wslMarker,
          posixProcessMarker: posixMarker,
          cwdResultPath: cwdResultPath,
        );
        final usesWindowsJobRunner =
            target.platform == BackgroundCommandPlatform.windows;
        final runner = usesWindowsJobRunner ? _windowsJobRunnerPath() : null;
        if (runner != null && !File(runner).existsSync()) {
          return CommandResult(
            output:
                '[ssterm background] Windows process runner is missing: $runner',
            exitCode: null,
          );
        }
        process = await (processStarter ?? Process.start)(
          runner ?? invocation.executable,
          runner == null
              ? invocation.arguments
              : [
                  '--parent-pid',
                  pid.toString(),
                  '--',
                  invocation.executable,
                  ...invocation.arguments,
                ],
          // WSL receives its Linux working directory through its own arguments.
          // Passing Agent's POSIX path to CreateProcess would instead be treated
          // as a Windows path and can prevent wsl.exe from starting.
          workingDirectory: target.processWorkingDirectory,
          runInShell: false,
          includeParentEnvironment: true,
          environment: environment,
        );
      } on ProcessException catch (error) {
        return CommandResult(
          output:
              '[ssterm background] Could not start ${target.shell.displayName}: $error',
          exitCode: null,
        );
      }
      var cancelled = isCancelled?.call() == true;
      var stalled = false;
      var lastOutputAt = DateTime.now();
      final stdout = _BoundedOutput(outputLimitBytes);
      final stderr = _BoundedOutput(outputLimitBytes);
      final liveOutput = _LiveOutputTail(onUpdate);
      final stdoutDone = process.stdout.listen((chunk) {
        stdout.add(chunk);
        lastOutputAt = DateTime.now();
        liveOutput.add(chunk);
      }).asFuture<void>();
      final stderrDone = process.stderr.listen((chunk) {
        stderr.add(chunk);
        lastOutputAt = DateTime.now();
        liveOutput.add(chunk);
      }).asFuture<void>();
      final completed = Future.wait<void>([
        process.exitCode.then<void>((_) {}),
        stdoutDone,
        stderrDone,
      ]);

      Future<void>? termination;
      final cancellationRequested = Completer<void>();
      Future<void> terminate(ProcessSignal signal) => _terminateLocalProcess(
        process,
        target,
        signal,
        wslMarker: wslMarker,
        posixMarker: posixMarker,
      );
      if (cancelled) {
        termination = terminate(ProcessSignal.sigterm);
        cancellationRequested.complete();
      }
      final cancellationPoll = Timer.periodic(
        const Duration(milliseconds: 50),
        (timer) {
          if (isCancelled?.call() != true || cancelled) return;
          cancelled = true;
          termination = terminate(ProcessSignal.sigterm);
          cancellationRequested.complete();
          timer.cancel();
        },
      );
      final silencePoll = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (cancelled || DateTime.now().difference(lastOutputAt) < silenceTimeout) {
          return;
        }
        stalled = true;
        cancelled = true;
        termination = terminate(ProcessSignal.sigterm);
        cancellationRequested.complete();
        timer.cancel();
      });

      final timedOut = await Future.any<bool>([
        completed.then((_) => false),
        Future<bool>.delayed(timeout, () => true),
        cancellationRequested.future.then((_) => false),
      ]);
      if (timedOut) {
        termination ??= terminate(ProcessSignal.sigterm);
      }
      await termination;

      if (timedOut || cancelled) {
        final stopped = await Future.any<bool>([
          completed.then((_) => true),
          Future<bool>.delayed(const Duration(seconds: 2), () => false),
        ]);
        if (!stopped) await terminate(ProcessSignal.sigkill);
      }
      await completed;
      cancellationPoll.cancel();
      silencePoll.cancel();
      if (wslMarker != null) {
        unawaited(_removeWslMarker(target.shell, wslMarker));
      }
      if (posixMarker != null) unawaited(_removePosixMarker(posixMarker));
      final status = stalled
          ? 'stopped after ${silenceTimeout.inSeconds}s without output; last output was reviewed as no progress'
          : cancelled
          ? 'cancelled'
          : timedOut
          ? 'timed out after ${timeout.inSeconds}s'
          : null;
      final exitCode = status == null ? await process.exitCode : null;
      final effectiveCwd = exitCode == 0
          ? await _readLocalCwdResult(cwdResultPath, target)
          : null;
      return CommandResult(
        output: _formatOutput(stdout, stderr, status),
        exitCode: exitCode,
        truncated: stdout.truncated || stderr.truncated,
        cancelled: cancelled,
        effectiveCwd: effectiveCwd,
      );
    } finally {
      try {
        await cwdResultDirectory.delete(recursive: true);
      } on FileSystemException {
        // The per-command directory is private and best-effort cleanup is
        // sufficient when the host filesystem has already removed it.
      }
    }
  }

  /// Executes one command through a dedicated non-PTY SSH session.
  ///
  /// The caller retains ownership of [client]. Cancellation closes only the
  /// created session, leaving the terminal session and SFTP untouched.
  Future<CommandResult> executeSsh(
    SSHClient client,
    String cwd,
    String command, {
    bool Function()? isCancelled,
    CommandExecutionUpdateListener? onUpdate,
  }) async {
    final safetyReason = CommandSafety.reason(command);
    if (safetyReason != null) {
      return CommandResult(
        output: '[ssterm safety check] $safetyReason',
        exitCode: null,
      );
    }
    if (isCancelled?.call() == true) {
      return CommandResult(
        output: '[ssterm background] cancelled',
        exitCode: null,
        cancelled: true,
      );
    }
    final cwdResultPath = _sshCwdResultPath();
    final stdout = _BoundedOutput(outputLimitBytes);
    final stderr = _BoundedOutput(outputLimitBytes);
    final liveOutput = _LiveOutputTail(onUpdate);
    late final SSHSession session;
    try {
      session = await (sshSessionStarter ?? _startSshSession)(
        client,
        buildSshBackgroundCommand(cwd, command, cwdResultPath: cwdResultPath),
      );
    } catch (error) {
      return CommandResult(
        output: '[ssterm background] Could not start SSH command: $error',
        exitCode: null,
      );
    }

    var cancelled = isCancelled?.call() == true;
    if (cancelled) {
      session.kill(SSHSignal.TERM);
      session.close();
    }
    final stdoutDone = session.stdout.listen((chunk) {
      stdout.add(chunk);
      liveOutput.add(chunk);
    }).asFuture<void>();
    final stderrDone = session.stderr.listen((chunk) {
      stderr.add(chunk);
      liveOutput.add(chunk);
    }).asFuture<void>();
    final completed = Future.wait<void>([session.done, stdoutDone, stderrDone]);
    final poll = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (isCancelled?.call() != true || cancelled) return;
      cancelled = true;
      session.kill(SSHSignal.TERM);
      session.close();
      timer.cancel();
    });
    final timedOut = await Future.any<bool>([
      completed.then((_) => false),
      Future<bool>.delayed(timeout, () => true),
    ]);
    if (timedOut) {
      session.kill(SSHSignal.TERM);
      session.close();
    }
    await completed;
    poll.cancel();
    final status = cancelled
        ? 'cancelled'
        : timedOut
        ? 'timed out after ${timeout.inSeconds}s'
        : null;
    final exitCode = status == null ? session.exitCode : null;
    List<int>? cwdBytes;
    try {
      cwdBytes = await (sshCwdResultReader ?? _readAndRemoveSshCwdResult)(
        client,
        cwdResultPath,
      );
    } catch (_) {
      cwdBytes = null;
    }
    return CommandResult(
      output: _formatOutput(stdout, stderr, status),
      exitCode: exitCode,
      truncated: stdout.truncated || stderr.truncated,
      cancelled: cancelled,
      effectiveCwd: exitCode == 0
          ? _decodeCwdResult(cwdBytes, expectsPosix: true)
          : null,
    );
  }

  static String shellQuotePosix(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

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

  String _windowsJobRunnerPath() =>
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}'
      'flutter_pty_job_runner.exe';

  String _wslMarkerPath() =>
      '/tmp/ssterm-agent-$pid-${DateTime.now().microsecondsSinceEpoch}.pid';

  String _posixMarkerPath() =>
      '${Directory.systemTemp.path}/ssterm-agent-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}.pgid';

  String _randomNonce() {
    final random = Random.secure();
    return List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
  }

  String _sshCwdResultPath() => '/tmp/.ssterm-agent-cwd-${_randomNonce()}';

  Future<String?> _readLocalCwdResult(
    String resultPath,
    BackgroundCommandTarget target,
  ) async {
    final file = File(resultPath);
    try {
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > _maxCwdResultBytes) return null;
      final bytes = await file.readAsBytes();
      final expectsPosix =
          target.platform != BackgroundCommandPlatform.windows ||
          target.shell.isWsl ||
          target.shell.id.startsWith('git-bash') ||
          target.shell.executable.toLowerCase().endsWith('bash.exe');
      return _decodeCwdResult(bytes, expectsPosix: expectsPosix);
    } on FileSystemException {
      return null;
    }
  }

  String? _decodeCwdResult(List<int>? bytes, {required bool expectsPosix}) {
    if (bytes == null ||
        bytes.isEmpty ||
        bytes.length > _maxCwdResultBytes ||
        bytes.contains(0)) {
      return null;
    }
    try {
      final cwd = utf8.decode(bytes, allowMalformed: false);
      if (expectsPosix) return cwd.startsWith('/') ? cwd : null;
      final windowsAbsolute =
          RegExp(r'^[A-Za-z]:[\\/]').hasMatch(cwd) ||
          cwd.startsWith(r'\\') ||
          cwd.startsWith('//');
      return windowsAbsolute ? cwd : null;
    } on FormatException {
      return null;
    }
  }

  Future<List<int>?> _readAndRemoveSshCwdResult(
    SSHClient client,
    String resultPath,
  ) async {
    final session = await _startSshSession(
      client,
      buildSshCwdResultReadCommand(resultPath),
    );
    final bytes = BytesBuilder(copy: false);
    var overflow = false;
    final stdoutDone = session.stdout.listen((chunk) {
      final remaining = _maxCwdResultBytes + 1 - bytes.length;
      if (remaining <= 0) {
        overflow = true;
      } else if (chunk.length > remaining) {
        bytes.add(chunk.sublist(0, remaining));
        overflow = true;
      } else {
        bytes.add(chunk);
      }
    }).asFuture<void>();
    final stderrDone = session.stderr.listen((_) {}).asFuture<void>();
    await Future.wait<void>([session.done, stdoutDone, stderrDone]);
    if (overflow) return null;
    return bytes.takeBytes();
  }

  Future<void> _terminateWslProcessGroup(
    LocalShellOption shell,
    String marker,
  ) async {
    final distro = shell.id.startsWith('wsl:')
        ? shell.id.substring('wsl:'.length)
        : '';
    if (distro.isEmpty) return;
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    // The marker is written by the setsid session leader. Retrying covers the
    // narrow interval between CreateProcess and the first Linux instruction.
    for (var attempt = 0; attempt < 5; attempt++) {
      await Process.run('$root\\System32\\wsl.exe', [
        '-d',
        distro,
        '--',
        'sh',
        '-c',
        r'''test -r "$1" && { p=$(cat "$1"); kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p"; }''',
        'sh',
        marker,
      ], runInShell: false);
      if (attempt < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _removeWslMarker(LocalShellOption shell, String marker) async {
    final distro = shell.id.startsWith('wsl:')
        ? shell.id.substring('wsl:'.length)
        : '';
    if (distro.isEmpty) return;
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    await Process.run('$root\\System32\\wsl.exe', [
      '-d',
      distro,
      '--',
      'rm',
      '-f',
      '--',
      marker,
    ], runInShell: false);
  }

  Future<void> _terminateLocalProcess(
    Process process,
    BackgroundCommandTarget target,
    ProcessSignal signal, {
    required String? wslMarker,
    required String? posixMarker,
  }) async {
    if (wslMarker != null) {
      await _terminateWslProcessGroup(target.shell, wslMarker);
      process.kill(ProcessSignal.sigkill);
      return;
    }
    if (posixMarker != null) {
      final signalled = await _signalPosixProcessGroup(posixMarker, signal);
      if (!signalled && signal != ProcessSignal.sigkill) process.kill(signal);
      return;
    }
    process.kill(ProcessSignal.sigkill);
  }

  Future<bool> _signalPosixProcessGroup(
    String marker,
    ProcessSignal signal,
  ) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        final processGroup = int.tryParse(await File(marker).readAsString());
        if (processGroup != null && processGroup > 1) {
          return Process.killPid(-processGroup, signal);
        }
      } on FileSystemException {
        // The wrapper writes the process-group id immediately after launch.
      }
      if (attempt < 9) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    return false;
  }

  Future<void> _removePosixMarker(String marker) async {
    try {
      await File(marker).delete();
    } on FileSystemException {
      // The shell wrapper normally removes its marker before it exits.
    }
  }
}

String _wrapPosixCommandForCwdResult(String command, String resultPath) {
  final result = BackgroundCommandExecutor.shellQuotePosix(resultPath);
  return '$command\n'
      '__ssterm_exit=\$?\n'
      // A user DEBUG trap may still write ordinary stderr, but it cannot run
      // between or redirect the private result-file write below.
      'trap - DEBUG 2>/dev/null || true\n'
      '__ssterm_had_xtrace=0\n'
      'case \$- in *x*) __ssterm_had_xtrace=1; set +x ;; esac\n'
      'umask 077\n'
      'printf %s "\$PWD" > $result\n'
      'if [ "\$__ssterm_had_xtrace" = 1 ]; then set -x; fi\n'
      'exit "\$__ssterm_exit"';
}

String _posixProcessTreeSupervisor() {
  return '__ssterm_child=\n'
      '__ssterm_stopping=0\n'
      '__ssterm_gate=\$3.go\n'
      'rm -f -- "\$__ssterm_gate"\n'
      '__ssterm_signal_group() {\n'
      '  test -n "\$__ssterm_child" || return 0\n'
      '  kill "-\$1" -- "-\$__ssterm_child" 2>/dev/null || '
      'kill "-\$1" "\$__ssterm_child" 2>/dev/null\n'
      '}\n'
      '__ssterm_stop() {\n'
      '  __ssterm_stopping=1\n'
      '  __ssterm_signal_group TERM\n'
      '  __ssterm_signal_group CONT\n'
      '}\n'
      'trap __ssterm_stop TERM INT HUP\n'
      'test "\$__ssterm_stopping" = 0 || exit 143\n'
      'set -m\n'
      '"\$1" -c \'while [ ! -e "\$1" ]; do sleep 0.01; done; '
      'exec "\$2" -c "\$3"\' ssterm-command '
      '"\$__ssterm_gate" "\$1" "\$2" &\n'
      '__ssterm_child=\$!\n'
      'set +m\n'
      'if [ "\$__ssterm_stopping" != 0 ]; then\n'
      '  __ssterm_signal_group TERM\n'
      '  __ssterm_signal_group CONT\n'
      '  wait "\$__ssterm_child" 2>/dev/null\n'
      '  exit 143\n'
      'fi\n'
      'if ! printf %s "\$__ssterm_child" > "\$3"; then\n'
      '  __ssterm_signal_group KILL\n'
      '  __ssterm_signal_group CONT\n'
      '  wait "\$__ssterm_child" 2>/dev/null\n'
      '  exit 125\n'
      'fi\n'
      'if [ "\$__ssterm_stopping" = 0 ]; then\n'
      '  : > "\$__ssterm_gate"\n'
      'else\n'
      '  __ssterm_signal_group TERM\n'
      'fi\n'
      'wait "\$__ssterm_child"\n'
      '__ssterm_status=\$?\n'
      'while kill -0 "\$__ssterm_child" 2>/dev/null; do\n'
      '  wait "\$__ssterm_child"\n'
      '  __ssterm_status=\$?\n'
      'done\n'
      'while kill -0 -- "-\$__ssterm_child" 2>/dev/null; do\n'
      '  sleep 0.01\n'
      'done\n'
      'trap - TERM INT HUP\n'
      'rm -f -- "\$3" "\$__ssterm_gate"\n'
      'test "\$__ssterm_stopping" = 0 || exit 143\n'
      'exit "\$__ssterm_status"';
}

String _wrapCmdCommandForCwdResult(String command, String resultPath) {
  final quotedPath = resultPath.replaceAll('"', '""');
  return '$command\r\n'
      'set "__ssterm_exit=%errorlevel%"\r\n'
      '>& "$quotedPath" <nul set /p "=%CD%"\r\n'
      'exit /b %__ssterm_exit%';
}

String _wrapPowerShellCommandForCwdResult(String command, String resultPath) {
  final quotedPath = resultPath.replaceAll("'", "''");
  return '& { $command }\n'
      r'$__ssterm_exit = if ($?) { 0 } elseif ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }'
      '\n[IO.File]::WriteAllText(\'$quotedPath\', '
      r'(Get-Location).ProviderPath, [Text.UTF8Encoding]::new($false))'
      '\n'
      r'exit $__ssterm_exit';
}

String _wrapCommandForCwdResult(
  BackgroundCommandTarget target,
  String command,
  String resultPath,
) {
  if (target.platform != BackgroundCommandPlatform.windows ||
      target.shell.isWsl ||
      target.shell.id.startsWith('git-bash') ||
      target.shell.executable.toLowerCase().endsWith('bash.exe')) {
    return _wrapPosixCommandForCwdResult(command, resultPath);
  }
  if (target.shell.id == 'cmd') {
    return _wrapCmdCommandForCwdResult(command, resultPath);
  }
  if (target.shell.usePowerShellCwdWrapper) {
    return _wrapPowerShellCommandForCwdResult(command, resultPath);
  }
  return command;
}

/// Wraps an Agent SSH command in its independent working directory without
/// interpreting the command itself. Only [cwd] is shell-quoted here.
String buildSshBackgroundCommand(
  String cwd,
  String command, {
  String? cwdResultPath,
}) {
  final executionCommand = cwdResultPath != null
      ? _wrapPosixCommandForCwdResult(command, cwdResultPath)
      : command;
  return 'cd -- ${BackgroundCommandExecutor.shellQuotePosix(cwd)} && '
      '$executionCommand';
}

String buildSshCwdResultReadCommand(String resultPath) {
  final quotedPath = BackgroundCommandExecutor.shellQuotePosix(resultPath);
  return 'if [ -r $quotedPath ]; then head -c '
      '${_maxCwdResultBytes + 1} -- $quotedPath; fi; '
      'rm -f -- $quotedPath';
}

/// Reject known cross-shell probes before execution. This is deliberately
/// narrow: valid commands must remain the shell's responsibility, but these
/// forms are unambiguously accidental cmd.exe syntax in PowerShell and cause
/// misleading runtime failures.
String? validateBackgroundCommandSyntax(
  BackgroundCommandTarget target,
  String command,
) {
  if (!target.shell.usePowerShellCwdWrapper) return null;
  if (RegExp(
    r'(^|[;\r\n])\s*&\s*ver\b',
    caseSensitive: false,
  ).hasMatch(command)) {
    return 'PowerShell does not accept cmd.exe `& ver`. Use `\$PSVersionTable` '
        'or `cmd /c ver`.';
  }
  if (RegExp(
    r'(^|[;\r\n])\s*echo\s*;',
    caseSensitive: false,
  ).hasMatch(command)) {
    return 'PowerShell bare `echo` needs an argument. Use `Write-Output \'\'` '
        'or `[Console]::WriteLine()` for a blank line.';
  }
  return null;
}

/// Builds the non-interactive shell invocation used for a local background
/// command. Kept separate from process startup so every supported Windows
/// shell route can be tested without requiring that shell to be installed.
({String executable, List<String> arguments}) buildBackgroundCommandInvocation(
  BackgroundCommandTarget target,
  String command, {
  String? wslProcessMarker,
  String? posixProcessMarker,
  String? cwdResultPath,
}) {
  final shell = target.shell;
  final executionCommand = cwdResultPath != null
      ? _wrapCommandForCwdResult(target, command, cwdResultPath)
      : command;
  if (target.platform != BackgroundCommandPlatform.windows) {
    return (
      executable: posixProcessMarker == null ? shell.executable : '/bin/sh',
      arguments: [
        '-c',
        posixProcessMarker == null
            ? executionCommand
            : _posixProcessTreeSupervisor(),
        if (posixProcessMarker != null) ...[
          'ssterm-process-supervisor',
          shell.executable,
          executionCommand,
          posixProcessMarker,
        ],
      ],
    );
  }
  if (shell.id == 'cmd') {
    return (
      executable: shell.executable,
      arguments: ['/d', '/s', '/c', executionCommand],
    );
  }
  if (shell.usePowerShellCwdWrapper) {
    final utf8Prelude =
        r'''[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $OutputEncoding = [Console]::OutputEncoding; ''';
    return (
      executable: shell.executable,
      arguments: [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '$utf8Prelude$executionCommand',
      ],
    );
  }
  if (shell.id.startsWith('git-bash')) {
    return (
      executable: shell.executable,
      arguments: _gitBashCommandArguments(shell.arguments, executionCommand),
    );
  }
  if (shell.isWsl) {
    final distro = shell.id.startsWith('wsl:')
        ? shell.id.substring('wsl:'.length)
        : '';
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return (
      // [shell.arguments] is for the interactive terminal: it can contain a
      // login shell (`-li`) or a launcher wrapper. Reusing it here makes WSL
      // wait for an interactive session instead of running the command.
      executable: '$systemRoot\\System32\\wsl.exe',
      arguments: [
        if (distro.isNotEmpty) ...['-d', distro],
        '--cd',
        target.cwd.startsWith('/') ? target.cwd : '~',
        '--',
        'sh',
        '-lc',
        wslProcessMarker == null
            ? executionCommand
            : 'printf %s "\$\$" > '
                  '${BackgroundCommandExecutor.shellQuotePosix(wslProcessMarker)}; '
                  'exec sh -lc ${BackgroundCommandExecutor.shellQuotePosix(executionCommand)}',
      ],
    );
  }
  return (executable: shell.executable, arguments: ['-c', executionCommand]);
}

List<String> _gitBashCommandArguments(
  List<String> interactiveArguments,
  String command,
) {
  // Git Bash is discovered via `env.exe`, whose leading arguments establish
  // the MSYS environment and whose remaining arguments start an interactive
  // bash (`--login -i`). Keep only that environment prefix and replace the
  // terminal-only tail with a noninteractive shell command.
  final bashIndex = interactiveArguments.indexOf('/usr/bin/bash');
  final environment = bashIndex < 0
      ? const <String>[]
      : interactiveArguments.take(bashIndex).toList(growable: false);
  return [
    ...environment,
    '/usr/bin/bash',
    '--noprofile',
    '--norc',
    '-lc',
    command,
  ];
}

class _LiveOutputTail {
  _LiveOutputTail(this.onUpdate);

  final CommandExecutionUpdateListener? onUpdate;
  final List<String> _lines = [];
  String _partial = '';

  void add(List<int> chunk) {
    if (onUpdate == null || chunk.isEmpty) return;
    final text = utf8.decode(chunk, allowMalformed: true);
    final parts = ('$_partial$text').split('\n');
    _partial = parts.removeLast();
    _lines.addAll(parts.map((line) => line.replaceFirst(RegExp(r'\r$'), '')));
    if (_partial.isNotEmpty) {
      if (_lines.isEmpty || _lines.last != _partial) _lines.add(_partial);
    }
    while (_lines.length > 3) {
      _lines.removeAt(0);
    }
    onUpdate!(CommandExecutionUpdate(List.unmodifiable(_lines)));
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

  String get text {
    final bytes = _bytes.toBytes();
    // Windows PowerShell 5 writes redirected error records as UTF-16LE with a
    // BOM. The normal UTF-8 decode path turns Chinese error text into mojibake.
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16Le(bytes.sublist(2));
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16Be(bytes.sublist(2));
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  String _decodeUtf16Le(List<int> bytes) => String.fromCharCodes([
    for (var i = 0; i + 1 < bytes.length; i += 2)
      bytes[i] | (bytes[i + 1] << 8),
  ]);

  String _decodeUtf16Be(List<int> bytes) => String.fromCharCodes([
    for (var i = 0; i + 1 < bytes.length; i += 2)
      (bytes[i] << 8) | bytes[i + 1],
  ]);
}
