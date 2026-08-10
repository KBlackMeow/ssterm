import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ssterm/services/background_command_executor.dart';
import 'package:ssterm/services/local_shell_discovery.dart';

Future<void> main(List<String> arguments) async {
  try {
    await _run(arguments);
  } catch (error, stackTrace) {
    stderr.writeln(error);
    stderr.writeln(stackTrace);
    exit(1);
  }
  exit(0);
}

Future<void> _run(List<String> arguments) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('This smoke test only runs on Windows.');
  }

  final cwd = arguments.isEmpty ? Directory.current.path : arguments.single;
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final shell = LocalShellOption(
    id: 'powershell',
    displayName: 'PowerShell',
    executable: r'$systemRoot\System32\WindowsPowerShell\v1.0\powershell.exe'
        .replaceFirst(r'$systemRoot', systemRoot),
    usePowerShellCwdWrapper: true,
  );
  final target = BackgroundCommandTarget.local(
    shell: shell,
    cwd: cwd,
    platform: BackgroundCommandPlatform.windows,
  );
  const executor = BackgroundCommandExecutor(timeout: Duration(seconds: 10));

  final direct = await executor.executeLocal(
    target,
    r"[Console]::Out.Write('out'); [Console]::Error.Write('err'); exit 7",
  );
  _expect(direct.exitCode == 7, 'direct exit code was ${direct.exitCode}');
  _expect(direct.output.contains('out'), 'direct stdout was not captured');
  _expect(direct.output.contains('err'), 'direct stderr was not captured');

  final cwdResult = await executor.executeLocal(
    target,
    r'[Console]::Out.Write((Get-Location).Path)',
  );
  _expect(
    cwdResult.exitCode == 0,
    'cwd command exit code was ${cwdResult.exitCode}',
  );
  _expect(cwdResult.output.contains(cwd), 'Windows cwd was not propagated');

  // The runner must close its Job Object if its Flutter host exits, otherwise
  // a crash could orphan both the runner and its contained command tree.
  final host = await Process.start(shell.executable, [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'Start-Sleep -Seconds 2',
  ]);
  final runnerPath =
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}'
      'flutter_pty_job_runner.exe';
  final parentStopwatch = Stopwatch()..start();
  final orphanGuard = await Process.start(runnerPath, [
    '--parent-pid',
    host.pid.toString(),
    '--',
    shell.executable,
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    r'Write-Output $PID; Start-Sleep -Seconds 30',
  ]);
  final guardedOutput = utf8.decode(
    await orphanGuard.stdout.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    ),
  );
  final guardedExit = await orphanGuard.exitCode;
  _expect(guardedExit == 125, 'orphan guard exit code was $guardedExit');
  _expect(
    parentStopwatch.elapsed < const Duration(seconds: 5),
    'runner did not stop after its host exited',
  );
  final guardedPid = int.tryParse(guardedOutput.trim());
  _expect(guardedPid != null, 'runner child PID was not captured');
  final guardedProbe = await Process.run(shell.executable, [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "if (Get-Process -Id $guardedPid -ErrorAction SilentlyContinue) { exit 1 }",
  ]);
  _expect(guardedProbe.exitCode == 0, 'orphan-guarded child survived');

  final quoted = await executor.executeLocal(
    target,
    r"Write-Output 'QUOTED_OK: spaces, ampersand &, and apostrophe '''' '",
  );
  _expect(
    quoted.exitCode == 0,
    'quoted command exit code was ${quoted.exitCode}',
  );
  _expect(quoted.output.contains('QUOTED_OK:'), 'quoted command was mangled');

  final truncated = await const BackgroundCommandExecutor(
    timeout: Duration(seconds: 10),
    outputLimitBytes: 32,
  ).executeLocal(target, r"Write-Output ('x' * 128)");
  _expect(truncated.truncated, 'large output was not marked truncated');
  _expect(
    truncated.output.contains('output truncated'),
    'truncation marker missing',
  );

  final chineseError = await executor.executeLocal(
    target,
    "Write-Error '中文错误'; exit 1",
  );
  _expect(
    chineseError.exitCode == 1,
    'PowerShell error exit code was ${chineseError.exitCode}',
  );
  _expect(
    chineseError.output.contains('中文错误'),
    'PowerShell UTF-16 error output was not decoded correctly: ${chineseError.output}',
  );

  final timedOut = await const BackgroundCommandExecutor(
    timeout: Duration(seconds: 1),
  ).executeLocal(target, 'Start-Sleep -Seconds 30');
  _expect(timedOut.exitCode == null, 'timed-out command returned an exit code');
  _expect(
    timedOut.output.contains('timed out after 1s'),
    'timeout status missing',
  );

  final nativeLaunchFailure = await executor.executeLocal(
    BackgroundCommandTarget.local(
      shell: const LocalShellOption(
        id: 'powershell',
        displayName: 'Missing PowerShell',
        executable: r'Z:\missing\powershell.exe',
        usePowerShellCwdWrapper: true,
      ),
      cwd: cwd,
      platform: BackgroundCommandPlatform.windows,
    ),
    'Write-Output never',
  );
  _expect(
    nativeLaunchFailure.exitCode == 125,
    'native launch failure exit code was ${nativeLaunchFailure.exitCode}',
  );
  _expect(
    nativeLaunchFailure.output.contains('CreateProcessW failed'),
    'native launch failure diagnostic missing: ${nativeLaunchFailure.output}',
  );

  final cmd = await executor.executeLocal(
    BackgroundCommandTarget.local(
      shell: LocalShellOption(
        id: 'cmd',
        displayName: 'CMD',
        executable:
            Platform.environment['COMSPEC'] ?? r'C:\Windows\System32\cmd.exe',
      ),
      cwd: cwd,
      platform: BackgroundCommandPlatform.windows,
    ),
    'echo CMD_OK & exit /b 3',
  );
  _expect(cmd.exitCode == 3, 'cmd exit code was ${cmd.exitCode}');
  _expect(cmd.output.contains('CMD_OK'), 'cmd stdout was not captured');

  final wsl = await executor.executeLocal(
    BackgroundCommandTarget.local(
      shell: const LocalShellOption(
        id: 'wsl:Ubuntu',
        displayName: 'Ubuntu',
        // Deliberately terminal-only arguments: the executor must not reuse
        // them for a noninteractive Agent2 command.
        executable: 'ubuntu.exe',
        arguments: ['run', 'interactive wrapper'],
        isWsl: true,
      ),
      cwd: '/',
      platform: BackgroundCommandPlatform.windows,
    ),
    'printf WSL_OK',
  );
  _expect(wsl.exitCode == 0, 'WSL exit code was ${wsl.exitCode}');
  _expect(wsl.output.contains('WSL_OK'), 'WSL command did not complete');

  const gitBash = LocalShellOption(
    id: 'git-bash',
    displayName: 'Git Bash',
    executable: r'C:\Program Files\Git\usr\bin\env.exe',
    arguments: [
      'MSYSTEM=MINGW64',
      'MSYS=enable_pcon winsymlink:nativestrict',
      'CHERE_INVOKING=1',
      'SHELL=/usr/bin/bash',
      '/usr/bin/bash',
      '--login',
      '-i',
    ],
  );
  if (File(gitBash.executable).existsSync()) {
    final git = await executor.executeLocal(
      BackgroundCommandTarget.local(
        shell: gitBash,
        cwd: cwd,
        platform: BackgroundCommandPlatform.windows,
      ),
      'printf GIT_BASH_OK',
    );
    _expect(git.exitCode == 0, 'Git Bash exit code was ${git.exitCode}');
    _expect(
      git.output.contains('GIT_BASH_OK'),
      'Git Bash command did not complete',
    );
  }

  final stopwatch = Stopwatch()..start();
  final cancelled = await executor.executeLocal(
    target,
    r"$p = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -PassThru; Write-Output ('CHILD_PID=' + $p.Id); Wait-Process -Id $p.Id",
    isCancelled: () => stopwatch.elapsedMilliseconds >= 750,
  );
  _expect(cancelled.output.contains('cancelled'), 'command was not cancelled');

  final match = RegExp(r'CHILD_PID=(\d+)').firstMatch(cancelled.output);
  _expect(match != null, 'child PID was not captured before cancellation');
  final childPid = int.parse(match!.group(1)!);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final probe = await Process.run(shell.executable, [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) { exit 1 }",
  ]);
  _expect(probe.exitCode == 0, 'child process $childPid survived cancellation');

  stdout.writeln('Windows background execution smoke test passed.');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
