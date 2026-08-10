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
    this.outputLimitBytes = 256 * 1024,
    this.loginEnvironmentResolver,
    this.processStarter,
    this.sshSessionStarter,
  });

  final Duration timeout;
  final int outputLimitBytes;
  final LoginShellEnvironmentResolver? loginEnvironmentResolver;
  final BackgroundProcessStarter? processStarter;
  final BackgroundSshSessionStarter? sshSessionStarter;

  static final _defaultLoginEnvironmentResolver =
      LoginShellEnvironmentResolver();

  Future<CommandResult> executeLocal(
    BackgroundCommandTarget target,
    String command, {
    bool Function()? isCancelled,
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
    final completionMarker = _completionMarker();
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
    late final Process process;
    try {
      final invocation = buildBackgroundCommandInvocation(
        target,
        command,
        wslProcessMarker: wslMarker,
        posixProcessMarker: posixMarker,
        completionMarker: completionMarker,
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
    final stdout = _BoundedOutput(outputLimitBytes);
    final stderr = _BoundedOutput(outputLimitBytes);
    final stderrEnvelope = _CwdEnvelopeOutput(stderr, completionMarker);
    final stdoutDone = process.stdout.listen(stdout.add).asFuture<void>();
    final stderrDone = process.stderr
        .listen(stderrEnvelope.add)
        .asFuture<void>();
    final completed = Future.wait<void>([
      process.exitCode.then<void>((_) {}),
      stdoutDone,
      stderrDone,
    ]);

    Future<void>? termination;
    Future<void> terminate(ProcessSignal signal) => _terminateLocalProcess(
      process,
      target,
      signal,
      wslMarker: wslMarker,
      posixMarker: posixMarker,
    );
    if (cancelled) termination = terminate(ProcessSignal.sigterm);
    final cancellationPoll = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (isCancelled?.call() != true || cancelled) return;
      cancelled = true;
      termination = terminate(ProcessSignal.sigterm);
      timer.cancel();
    });

    final timedOut = await Future.any<bool>([
      completed.then((_) => false),
      Future<bool>.delayed(timeout, () => true),
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
    stderrEnvelope.close();
    cancellationPoll.cancel();
    if (wslMarker != null) unawaited(_removeWslMarker(target.shell, wslMarker));
    if (posixMarker != null) unawaited(_removePosixMarker(posixMarker));
    final status = cancelled
        ? 'cancelled'
        : timedOut
        ? 'timed out after ${timeout.inSeconds}s'
        : null;
    final exitCode = status == null ? await process.exitCode : null;
    return CommandResult(
      output: _formatOutput(stdout, stderr, status),
      exitCode: exitCode,
      truncated: stdout.truncated || stderr.truncated,
      cancelled: cancelled,
      effectiveCwd: exitCode == 0 ? stderrEnvelope.effectiveCwd : null,
    );
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
    final completionMarker = _completionMarker();
    final stdout = _BoundedOutput(outputLimitBytes);
    final stderr = _BoundedOutput(outputLimitBytes);
    final stderrEnvelope = _CwdEnvelopeOutput(stderr, completionMarker);
    late final SSHSession session;
    try {
      session = await (sshSessionStarter ?? _startSshSession)(
        client,
        buildSshBackgroundCommand(
          cwd,
          command,
          completionMarker: completionMarker,
        ),
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
    final stdoutDone = session.stdout.listen(stdout.add).asFuture<void>();
    final stderrDone = session.stderr
        .listen(stderrEnvelope.add)
        .asFuture<void>();
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
    stderrEnvelope.close();
    poll.cancel();
    final status = cancelled
        ? 'cancelled'
        : timedOut
        ? 'timed out after ${timeout.inSeconds}s'
        : null;
    final exitCode = status == null ? session.exitCode : null;
    return CommandResult(
      output: _formatOutput(stdout, stderr, status),
      exitCode: exitCode,
      truncated: stdout.truncated || stderr.truncated,
      cancelled: cancelled,
      effectiveCwd: exitCode == 0 ? stderrEnvelope.effectiveCwd : null,
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

  String _completionMarker() {
    final random = Random.secure();
    final nonce = List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '__SSTERM_CWD_${nonce}__';
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
      if (!signalled) process.kill(signal);
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

String _wrapPosixCommandForCwd(String command, String marker) {
  final begin = BackgroundCommandExecutor.shellQuotePosix('${marker}BEGIN__');
  final end = BackgroundCommandExecutor.shellQuotePosix('${marker}END__');
  return '$command\n'
      '__ssterm_exit=\$?\n'
      '__ssterm_had_xtrace=0\n'
      'case \$- in *x*) __ssterm_had_xtrace=1; set +x ;; esac\n'
      'printf %s $begin >&2\n'
      'printf %s "\$PWD" >&2\n'
      'printf %s $end >&2\n'
      'if [ "\$__ssterm_had_xtrace" = 1 ]; then set -x; fi\n'
      'exit "\$__ssterm_exit"';
}

String _posixProcessTreeSupervisor() {
  return 'set -m\n'
      '"\$1" -c "\$2" &\n'
      '__ssterm_child=\$!\n'
      'set +m\n'
      'printf %s "\$__ssterm_child" > "\$3"\n'
      '__ssterm_stop() {\n'
      '  trap - TERM INT HUP\n'
      '  kill -TERM -- "-\$__ssterm_child" 2>/dev/null || '
      'kill -TERM "\$__ssterm_child" 2>/dev/null\n'
      '  wait "\$__ssterm_child" 2>/dev/null\n'
      '  rm -f -- "\$3"\n'
      '  exit 143\n'
      '}\n'
      'trap __ssterm_stop TERM INT HUP\n'
      'wait "\$__ssterm_child"\n'
      '__ssterm_status=\$?\n'
      'trap - TERM INT HUP\n'
      'rm -f -- "\$3"\n'
      'exit "\$__ssterm_status"';
}

String _wrapCmdCommandForCwd(String command, String marker) =>
    '$command\r\n'
    'set "__ssterm_exit=%errorlevel%"\r\n'
    '>&2 <nul set /p "=${marker}BEGIN__%CD%${marker}END__"\r\n'
    'exit /b %__ssterm_exit%';

String _wrapPowerShellCommandForCwd(String command, String marker) {
  final quotedMarker = marker.replaceAll("'", "''");
  return '& { $command }\n'
      r'$__ssterm_exit = if ($?) { 0 } elseif ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }'
      '\n[Console]::Error.Write(\'${quotedMarker}BEGIN__\')\n'
      r'[Console]::Error.Write((Get-Location).ProviderPath)'
      '\n'
      '[Console]::Error.Write(\'${quotedMarker}END__\')\n'
      r'exit $__ssterm_exit';
}

String _wrapCommandForCwd(
  BackgroundCommandTarget target,
  String command,
  String marker,
) {
  if (target.platform != BackgroundCommandPlatform.windows ||
      target.shell.isWsl ||
      target.shell.id.startsWith('git-bash') ||
      target.shell.executable.toLowerCase().endsWith('bash.exe')) {
    return _wrapPosixCommandForCwd(command, marker);
  }
  if (target.shell.id == 'cmd') {
    return _wrapCmdCommandForCwd(command, marker);
  }
  if (target.shell.usePowerShellCwdWrapper) {
    return _wrapPowerShellCommandForCwd(command, marker);
  }
  return command;
}

/// Wraps an Agent SSH command in its independent working directory without
/// interpreting the command itself. Only [cwd] is shell-quoted here.
String buildSshBackgroundCommand(
  String cwd,
  String command, {
  String? completionMarker,
}) {
  final executionCommand = completionMarker == null
      ? command
      : _wrapPosixCommandForCwd(command, completionMarker);
  return 'cd -- ${BackgroundCommandExecutor.shellQuotePosix(cwd)} && '
      '$executionCommand';
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
  String? completionMarker,
}) {
  final shell = target.shell;
  final executionCommand = completionMarker == null
      ? command
      : _wrapCommandForCwd(target, command, completionMarker);
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

class _CwdEnvelopeOutput {
  _CwdEnvelopeOutput(this.output, String marker)
    : _begin = utf8.encode('${marker}BEGIN__'),
      _end = utf8.encode('${marker}END__');

  final _BoundedOutput output;
  final List<int> _begin;
  final List<int> _end;
  List<int> _pending = <int>[];
  List<int>? _cwd;
  bool _insideFrame = false;

  void add(List<int> chunk) {
    _pending.addAll(chunk);
    while (true) {
      if (!_insideFrame) {
        final beginIndex = _indexOf(_pending, _begin);
        if (beginIndex < 0) {
          final retained = min(_begin.length - 1, _pending.length);
          final safeLength = _pending.length - retained;
          if (safeLength > 0) output.add(_pending.sublist(0, safeLength));
          _pending = _pending.sublist(safeLength);
          return;
        }
        output.add(_pending.sublist(0, beginIndex));
        _pending = _pending.sublist(beginIndex + _begin.length);
        _insideFrame = true;
      }

      final endIndex = _indexOf(_pending, _end);
      if (endIndex < 0) return;
      final candidate = _pending.sublist(0, endIndex);
      final trailing = _pending.sublist(endIndex + _end.length);
      if (_validCwd(candidate)) {
        _cwd = candidate;
      } else {
        output.add([..._begin, ...candidate, ..._end]);
      }
      _insideFrame = false;
      _pending = trailing;
    }
  }

  void close() {
    if (_pending.isNotEmpty) {
      output.add([if (_insideFrame) ..._begin, ..._pending]);
    }
    _pending = <int>[];
  }

  String? get effectiveCwd {
    final cwd = _cwd;
    return cwd == null ? null : utf8.decode(cwd, allowMalformed: false);
  }

  bool _validCwd(List<int> candidate) {
    if (candidate.isEmpty || candidate.contains(0)) return false;
    try {
      utf8.decode(candidate, allowMalformed: false);
      return true;
    } on FormatException {
      return false;
    }
  }

  int _indexOf(List<int> bytes, List<int> pattern) {
    if (pattern.isEmpty || bytes.length < pattern.length) return -1;
    for (var i = 0; i <= bytes.length - pattern.length; i++) {
      var matches = true;
      for (var j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return i;
    }
    return -1;
  }
}
