import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/background_command_executor.dart';
import 'package:ssterm/services/login_shell_environment.dart';
import 'package:ssterm/services/local_shell_discovery.dart';

class _UnusedSshClient implements SSHClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('SSH client must not be used');
}

class _FakeSshSession implements SSHSession {
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();

  SSHSignal? killedWith;
  bool closed = false;
  int? exitCodeValue;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => exitCodeValue;

  @override
  void kill(SSHSignal signal) => killedWith = signal;

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _done.complete();
  }

  void complete({String stdout = '', String stderr = '', int? exitCode = 0}) {
    scheduleMicrotask(() async {
      exitCodeValue = exitCode;
      if (stdout.isNotEmpty) _stdout.add(Uint8List.fromList(stdout.codeUnits));
      if (stderr.isNotEmpty) _stderr.add(Uint8List.fromList(stderr.codeUnits));
      await _stdout.close();
      await _stderr.close();
      if (!_done.isCompleted) _done.complete();
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProcess implements Process {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exitCode = Completer<int>();

  bool killed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  void complete([int code = 0]) {
    scheduleMicrotask(() async {
      if (!_exitCode.isCompleted) _exitCode.complete(code);
      await _stdout.close();
      await _stderr.close();
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('BackgroundCommandTarget.local', () {
    const zsh = LocalShellOption(
      id: 'zsh',
      displayName: 'Zsh',
      executable: '/bin/zsh',
    );

    test('accepts zsh on macOS and Linux', () {
      expect(
        BackgroundCommandTarget.local(
          shell: zsh,
          cwd: '/tmp',
          platform: BackgroundCommandPlatform.macos,
        ).support.isSupported,
        isTrue,
      );
      expect(
        BackgroundCommandTarget.local(
          shell: zsh,
          cwd: '/tmp',
          platform: BackgroundCommandPlatform.linux,
        ).support.isSupported,
        isTrue,
      );
    });

    test('supports known Windows shells and rejects unknown ones', () {
      const powershell = LocalShellOption(
        id: 'powershell',
        displayName: 'PowerShell',
        executable: 'powershell.exe',
        usePowerShellCwdWrapper: true,
      );
      const wsl = LocalShellOption(
        id: 'wsl:ubuntu',
        displayName: 'Ubuntu (WSL)',
        executable: 'wsl.exe',
        isWsl: true,
      );

      final windows = BackgroundCommandTarget.local(
        shell: zsh,
        cwd: r'C:\work',
        platform: BackgroundCommandPlatform.windows,
      );
      expect(windows.support.isSupported, isFalse);
      expect(windows.support.reason, contains('Windows'));

      expect(
        BackgroundCommandTarget.local(
          shell: powershell,
          cwd: r'C:\work',
          platform: BackgroundCommandPlatform.windows,
        ).support.isSupported,
        isTrue,
      );
      expect(
        BackgroundCommandTarget.local(
          shell: wsl,
          cwd: r'C:\work',
          platform: BackgroundCommandPlatform.windows,
        ).support.isSupported,
        isTrue,
      );

      expect(
        BackgroundCommandTarget.local(
          shell: powershell,
          cwd: '/tmp',
          platform: BackgroundCommandPlatform.macos,
        ).support.isSupported,
        isFalse,
      );
      expect(
        BackgroundCommandTarget.local(
          shell: wsl,
          cwd: '/tmp',
          platform: BackgroundCommandPlatform.linux,
        ).support.isSupported,
        isFalse,
      );
    });

    test('builds cmd, PowerShell, Git Bash, and WSL invocations', () {
      BackgroundCommandTarget windows(LocalShellOption shell) =>
          BackgroundCommandTarget.local(
            shell: shell,
            cwd: r'C:\work',
            platform: BackgroundCommandPlatform.windows,
          );

      expect(
        buildBackgroundCommandInvocation(
          windows(
            const LocalShellOption(
              id: 'cmd',
              displayName: 'CMD',
              executable: 'cmd.exe',
            ),
          ),
          'echo ok',
        ).arguments,
        ['/d', '/s', '/c', 'echo ok'],
      );
      expect(
        buildBackgroundCommandInvocation(
          windows(
            const LocalShellOption(
              id: 'pwsh',
              displayName: 'PowerShell',
              executable: 'pwsh.exe',
              usePowerShellCwdWrapper: true,
            ),
          ),
          'Write-Output ok',
        ).arguments.take(3),
        ['-NoProfile', '-NonInteractive', '-Command'],
      );
      expect(
        buildBackgroundCommandInvocation(
          windows(
            const LocalShellOption(
              id: 'pwsh',
              displayName: 'PowerShell',
              executable: 'pwsh.exe',
              usePowerShellCwdWrapper: true,
            ),
          ),
          'Write-Output ok',
        ).arguments.last,
        contains('[Console]::OutputEncoding'),
      );
      expect(
        buildBackgroundCommandInvocation(
          windows(
            const LocalShellOption(
              id: 'git-bash',
              displayName: 'Git Bash',
              executable: 'env.exe',
              arguments: [
                'MSYSTEM=MINGW64',
                'MSYS=enable_pcon winsymlink:nativestrict',
                'CHERE_INVOKING=1',
                'SHELL=/usr/bin/bash',
                '/usr/bin/bash',
                '--login',
                '-i',
              ],
            ),
          ),
          'printf ok',
        ).arguments,
        [
          'MSYSTEM=MINGW64',
          'MSYS=enable_pcon winsymlink:nativestrict',
          'CHERE_INVOKING=1',
          'SHELL=/usr/bin/bash',
          '/usr/bin/bash',
          '--noprofile',
          '--norc',
          '-lc',
          'printf ok',
        ],
      );
      final wsl = buildBackgroundCommandInvocation(
        windows(
          const LocalShellOption(
            id: 'wsl:ubuntu',
            displayName: 'Ubuntu',
            executable: 'wsl.exe',
            arguments: ['-d', 'Ubuntu'],
            isWsl: true,
          ),
        ),
        'printf ok',
      );
      expect(
        wsl.executable,
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\wsl.exe',
      );
      expect(wsl.arguments, [
        '-d',
        'ubuntu',
        '--cd',
        '~',
        '--',
        'sh',
        '-lc',
        'printf ok',
      ]);

      final wslWithGroup = buildBackgroundCommandInvocation(
        BackgroundCommandTarget.local(
          shell: const LocalShellOption(
            id: 'wsl:ubuntu',
            displayName: 'Ubuntu',
            executable: 'wsl.exe',
            isWsl: true,
          ),
          cwd: '/home/tester/project',
          platform: BackgroundCommandPlatform.windows,
        ),
        'sleep 1',
        wslProcessMarker: '/tmp/ssterm-test.pid',
      );
      expect(
        wslWithGroup.arguments,
        containsAllInOrder([
          '--cd',
          '/home/tester/project',
          '--',
          'sh',
          '-lc',
          contains(r'printf %s "$$" >'),
        ]),
      );
    });

    test('adds a cwd completion envelope for every Windows shell route', () {
      const marker = '__SSTERM_CWD_TEST__';
      BackgroundCommandTarget windows(LocalShellOption shell) =>
          BackgroundCommandTarget.local(
            shell: shell,
            cwd: r'C:\work',
            platform: BackgroundCommandPlatform.windows,
          );

      final cmd = buildBackgroundCommandInvocation(
        windows(
          const LocalShellOption(
            id: 'cmd',
            displayName: 'CMD',
            executable: 'cmd.exe',
          ),
        ),
        'cd child',
        completionMarker: marker,
      ).arguments.last;
      expect(cmd, contains(marker));
      expect(cmd, contains('%CD%'));

      final powershell = buildBackgroundCommandInvocation(
        windows(
          const LocalShellOption(
            id: 'pwsh',
            displayName: 'PowerShell',
            executable: 'pwsh.exe',
            usePowerShellCwdWrapper: true,
          ),
        ),
        'Set-Location child',
        completionMarker: marker,
      ).arguments.last;
      expect(powershell, contains(marker));
      expect(powershell, contains(r'(Get-Location).ProviderPath'));

      final gitBash = buildBackgroundCommandInvocation(
        windows(
          const LocalShellOption(
            id: 'git-bash',
            displayName: 'Git Bash',
            executable: 'env.exe',
            arguments: ['/usr/bin/bash', '--login', '-i'],
          ),
        ),
        'cd child',
        completionMarker: marker,
      ).arguments.last;
      expect(gitBash, contains(marker));
      expect(gitBash, contains(r'"$PWD"'));

      final wsl = buildBackgroundCommandInvocation(
        windows(
          const LocalShellOption(
            id: 'wsl:ubuntu',
            displayName: 'Ubuntu',
            executable: 'wsl.exe',
            isWsl: true,
          ),
        ),
        'cd child',
        completionMarker: marker,
      ).arguments.last;
      expect(wsl, contains(marker));
      expect(wsl, contains(r'"$PWD"'));
    });

    test('rejects known cmd probes in PowerShell before execution', () {
      const shell = LocalShellOption(
        id: 'powershell',
        displayName: 'PowerShell',
        executable: 'powershell.exe',
        usePowerShellCwdWrapper: true,
      );
      final target = BackgroundCommandTarget.local(
        shell: shell,
        cwd: r'C:\work',
        platform: BackgroundCommandPlatform.windows,
      );
      expect(
        validateBackgroundCommandSyntax(target, 'echo "x"; & ver'),
        contains('cmd.exe'),
      );
      expect(
        validateBackgroundCommandSyntax(target, 'echo; Get-Date'),
        contains('bare `echo`'),
      );
      expect(
        validateBackgroundCommandSyntax(target, 'Write-Output ok'),
        isNull,
      );
    });

    test('uses a native working directory while retaining Git Bash cwd', () {
      const shell = LocalShellOption(
        id: 'git-bash',
        displayName: 'Git Bash',
        executable: r'C:\Program Files\Git\usr\bin\env.exe',
      );
      final target = BackgroundCommandTarget.local(
        shell: shell,
        cwd: '/d/work/project',
        platform: BackgroundCommandPlatform.windows,
      );

      expect(target.processWorkingDirectory, r'D:\work\project');
      expect(target.cwd, '/d/work/project');
    });
  });

  group('BackgroundCommandExecutor', () {
    const zsh = LocalShellOption(
      id: 'zsh',
      displayName: 'Zsh',
      executable: '/bin/zsh',
    );

    test(
      'rejects operationally unsafe commands before starting a process',
      () async {
        var starts = 0;
        final executor = BackgroundCommandExecutor(
          processStarter:
              (
                executable,
                arguments, {
                workingDirectory,
                runInShell = false,
                includeParentEnvironment = true,
                environment,
              }) async {
                starts++;
                throw StateError('process starter must not be called');
              },
        );

        final result = await executor.executeLocal(
          BackgroundCommandTarget.local(
            shell: zsh,
            cwd: Directory.current.path,
            platform: BackgroundCommandPlatform.macos,
          ),
          'sleep 1 &',
        );

        expect(starts, 0);
        expect(result.exitCode, isNull);
        expect(result.output, contains('[ssterm safety check]'));
      },
    );

    test(
      'rejects operationally unsafe commands before opening an SSH channel',
      () async {
        var starts = 0;
        final executor = BackgroundCommandExecutor(
          sshSessionStarter: (client, command) async {
            starts++;
            throw StateError('SSH channel starter must not be called');
          },
        );

        final result = await executor.executeSsh(
          _UnusedSshClient(),
          '/srv',
          'tail -f app.log',
        );

        expect(starts, 0);
        expect(result.exitCode, isNull);
        expect(result.output, contains('[ssterm safety check]'));
      },
    );

    test(
      'does not open an SSH channel after cancellation was invalidated',
      () async {
        var starts = 0;
        final executor = BackgroundCommandExecutor(
          sshSessionStarter: (client, command) async {
            starts++;
            throw StateError('SSH channel starter must not be called');
          },
        );

        final result = await executor.executeSsh(
          _UnusedSshClient(),
          '/srv',
          'printf ok',
          isCancelled: () => true,
        );

        expect(starts, 0);
        expect(result.cancelled, isTrue);
      },
    );

    test(
      'returns stdout, stderr, and the shell exit code without a PTY',
      () async {
        final shell = Platform.isWindows ? LocalShellDiscovery.fallback() : zsh;
        final platform = Platform.isWindows
            ? BackgroundCommandPlatform.windows
            : BackgroundCommandPlatform.macos;
        final command = Platform.isWindows
            ? 'echo out & echo err 1>&2 & exit /b 7'
            : 'printf out; printf err >&2; exit 7';
        final result = await const BackgroundCommandExecutor().executeLocal(
          BackgroundCommandTarget.local(
            shell: shell,
            cwd: Directory.current.path,
            platform: platform,
          ),
          command,
        );

        expect(result.exitCode, 7);
        expect(result.output, contains('[stdout]\nout'));
        expect(result.output, contains('[stderr]\nerr'));
        expect(result.truncated, isFalse);
      },
      skip: Platform.isWindows
          ? 'Covered by tool/windows_background_smoke.dart with the packaged DLL.'
          : false,
    );

    test(
      'cancels and awaits an in-flight POSIX command process tree',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'ssterm-cancel-tree-',
        );
        final pidFile = File('${root.path}/child.pid');
        addTearDown(() => root.delete(recursive: true));
        var cancelled = false;
        final stopwatch = Stopwatch()..start();

        final pending =
            const BackgroundCommandExecutor(
              timeout: Duration(seconds: 10),
            ).executeLocal(
              BackgroundCommandTarget.local(
                shell: zsh,
                cwd: Directory.current.path,
                platform: BackgroundCommandPlatform.macos,
              ),
              'sh -c ${BackgroundCommandExecutor.shellQuotePosix('printf %s "\$\$" > ${BackgroundCommandExecutor.shellQuotePosix(pidFile.path)}; exec sleep 5')}',
              isCancelled: () => cancelled,
            );

        for (
          var attempt = 0;
          attempt < 200 && !await pidFile.exists();
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await pidFile.exists(), isTrue);
        final childPid = int.parse((await pidFile.readAsString()).trim());
        cancelled = true;
        final result = await pending;
        stopwatch.stop();

        expect(result.exitCode, isNull);
        expect(result.output, contains('cancelled'));
        expect(result.cancelled, isTrue);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
        final stillRunning = await Process.run('/bin/kill', [
          '-0',
          childPid.toString(),
        ]);
        expect(stillRunning.exitCode, isNot(0));
      },
      skip: Platform.isWindows
          ? 'Covered by tool/windows_background_smoke.dart with the packaged DLL.'
          : false,
    );

    test(
      'cancels a local command invalidated while Process.start completes',
      () async {
        final process = _FakeProcess();
        var cancelled = false;
        final executor = BackgroundCommandExecutor(
          processStarter:
              (
                executable,
                arguments, {
                workingDirectory,
                runInShell = false,
                includeParentEnvironment = true,
                environment,
              }) async {
                cancelled = true;
                process.complete();
                return process;
              },
        );

        final result = await executor.executeLocal(
          BackgroundCommandTarget.local(
            shell: zsh,
            cwd: Directory.current.path,
            platform: BackgroundCommandPlatform.macos,
          ),
          'printf ok',
          isCancelled: () => cancelled,
        );

        expect(process.killed, isTrue);
        expect(result.cancelled, isTrue);
        expect(result.exitCode, isNull);
      },
    );

    test('cancels only the per-command SSH channel', () async {
      final session = _FakeSshSession();
      var cancelled = false;
      final executor = BackgroundCommandExecutor(
        timeout: const Duration(seconds: 5),
        sshSessionStarter: (client, command) async {
          cancelled = true;
          return session;
        },
      );

      final result = await executor.executeSsh(
        _UnusedSshClient(),
        '/srv',
        'sleep 5',
        isCancelled: () => cancelled,
      );

      expect(session.killedWith, SSHSignal.TERM);
      expect(session.closed, isTrue);
      expect(result.exitCode, isNull);
      expect(result.cancelled, isTrue);
    });

    test(
      'cancels an SSH command invalidated while session start completes',
      () async {
        final session = _FakeSshSession();
        var cancelled = false;
        final executor = BackgroundCommandExecutor(
          sshSessionStarter: (client, command) async {
            cancelled = true;
            session.complete();
            return session;
          },
        );

        final result = await executor.executeSsh(
          _UnusedSshClient(),
          '/srv',
          'printf ok',
          isCancelled: () => cancelled,
        );

        expect(session.killedWith, SSHSignal.TERM);
        expect(session.closed, isTrue);
        expect(result.cancelled, isTrue);
        expect(result.exitCode, isNull);
      },
    );

    test('uses the Agent cwd', () async {
      final dir = await Directory.systemTemp.createTemp('ssterm-agent-cwd-');
      addTearDown(() => dir.delete(recursive: true));

      final result = await const BackgroundCommandExecutor().executeLocal(
        BackgroundCommandTarget.local(
          shell: zsh,
          cwd: dir.path,
          platform: BackgroundCommandPlatform.macos,
        ),
        'pwd',
      );

      expect(result.output, contains(dir.path));
    });

    test('returns a verified cwd for the next local command', () async {
      final root = await Directory.systemTemp.createTemp('ssterm-agent-cwd-');
      final child = await Directory('${root.path}/child').create();
      addTearDown(() => root.delete(recursive: true));
      const executor = BackgroundCommandExecutor();

      final changed = await executor.executeLocal(
        BackgroundCommandTarget.local(
          shell: zsh,
          cwd: root.path,
          platform: BackgroundCommandPlatform.macos,
        ),
        'cd child',
      );
      final verifiedCwd = changed.effectiveCwd;
      final canonicalChild = await child.resolveSymbolicLinks();
      expect(verifiedCwd, canonicalChild);

      final next = await executor.executeLocal(
        BackgroundCommandTarget.local(
          shell: zsh,
          cwd: verifiedCwd!,
          platform: BackgroundCommandPlatform.macos,
        ),
        'pwd',
      );

      expect(next.output, contains(canonicalChild));
    });

    test(
      'uses a complete cwd frame and preserves later traced stderr',
      () async {
        final root = await Directory.systemTemp.createTemp('ssterm-cwd-frame-');
        final child = await Directory('${root.path}/child').create();
        addTearDown(() => root.delete(recursive: true));

        final result = await const BackgroundCommandExecutor().executeLocal(
          BackgroundCommandTarget.local(
            shell: zsh,
            cwd: root.path,
            platform: BackgroundCommandPlatform.macos,
          ),
          "set -x\ntrap 'printf late-trap >&2' EXIT\ncd child",
        );

        expect(result.exitCode, 0);
        expect(result.effectiveCwd, await child.resolveSymbolicLinks());
        expect(result.output, contains('late-trap'));
        expect(result.output, isNot(contains('__SSTERM_CWD_')));
      },
    );

    test('uses the resolved login-shell PATH for a POSIX command', () async {
      final resolver = LoginShellEnvironmentResolver(
        readPath: (_) async => '/ssterm-login-shell-path',
      );
      final result =
          await BackgroundCommandExecutor(
            loginEnvironmentResolver: resolver,
          ).executeLocal(
            BackgroundCommandTarget.local(
              shell: zsh,
              cwd: Directory.current.path,
              platform: BackgroundCommandPlatform.macos,
            ),
            r'printf %s "$PATH"',
          );

      expect(result.exitCode, 0);
      expect(result.output, contains('/ssterm-login-shell-path'));
    });

    test('does not resolve a login-shell PATH for a Windows target', () async {
      var calls = 0;
      final resolver = LoginShellEnvironmentResolver(
        readPath: (_) async {
          calls++;
          return '/should-not-be-used';
        },
      );

      await BackgroundCommandExecutor(
        loginEnvironmentResolver: resolver,
      ).executeLocal(
        BackgroundCommandTarget.local(
          shell: const LocalShellOption(
            id: 'cmd',
            displayName: 'CMD',
            executable: 'cmd.exe',
          ),
          cwd: Directory.current.path,
          platform: BackgroundCommandPlatform.windows,
        ),
        'echo ok',
      );

      expect(calls, 0);
    });

    test('marks output that exceeds its cap', () async {
      final result = await const BackgroundCommandExecutor(outputLimitBytes: 3)
          .executeLocal(
            BackgroundCommandTarget.local(
              shell: zsh,
              cwd: Directory.current.path,
              platform: BackgroundCommandPlatform.macos,
            ),
            'printf 12345',
          );

      expect(result.truncated, isTrue);
      expect(result.output, contains('output truncated'));
    });

    test(
      'returns a timeout result for a command that does not finish',
      () async {
        final result =
            await const BackgroundCommandExecutor(
              timeout: Duration(milliseconds: 20),
            ).executeLocal(
              BackgroundCommandTarget.local(
                shell: zsh,
                cwd: Directory.current.path,
                platform: BackgroundCommandPlatform.macos,
              ),
              'sleep 5',
            );

        expect(result.exitCode, isNull);
        expect(result.output, contains('timed out'));
      },
    );
  });

  group('SSH background command construction', () {
    test('quotes cwd before appending the unmodified command', () {
      expect(
        buildSshBackgroundCommand("/srv/O'Reilly project", 'printf ok'),
        "cd -- '/srv/O'\\''Reilly project' && printf ok",
      );
    });

    test(
      'returns the remote cwd from a verified completion envelope',
      () async {
        final session = _FakeSshSession();
        final executor = BackgroundCommandExecutor(
          sshSessionStarter: (client, command) async {
            final marker = RegExp(
              r"printf %s '(__SSTERM_CWD_[^']+__)BEGIN__' >&2",
            ).firstMatch(command)?.group(1);
            if (marker == null) throw StateError('missing cwd envelope');
            session.complete(
              stderr: '${marker}BEGIN__/srv/project${marker}END__',
            );
            return session;
          },
        );

        final result = await executor.executeSsh(
          _UnusedSshClient(),
          '/srv',
          'cd project',
        );

        expect(result.exitCode, 0);
        expect(result.effectiveCwd, '/srv/project');
        expect(result.output, isNot(contains('__SSTERM_CWD_')));
      },
    );

    test(
      'uses the last valid complete cwd frame and strips only frames',
      () async {
        final session = _FakeSshSession();
        final executor = BackgroundCommandExecutor(
          sshSessionStarter: (client, command) async {
            final marker = RegExp(
              r"printf %s '(__SSTERM_CWD_[^']+__)BEGIN__' >&2",
            ).firstMatch(command)?.group(1);
            if (marker == null) throw StateError('missing cwd envelope');
            session.complete(
              stderr:
                  'before${marker}BEGIN__/first${marker}END__middle'
                  '${marker}BEGIN__/last${marker}END__after',
            );
            return session;
          },
        );

        final result = await executor.executeSsh(
          _UnusedSshClient(),
          '/srv',
          'cd project',
        );

        expect(result.effectiveCwd, '/last');
        expect(result.output, contains('beforemiddleafter'));
        expect(result.output, isNot(contains('__SSTERM_CWD_')));
      },
    );

    test('applies the output cap to bytes after a cwd frame', () async {
      final session = _FakeSshSession();
      final executor = BackgroundCommandExecutor(
        outputLimitBytes: 4,
        sshSessionStarter: (client, command) async {
          final marker = RegExp(
            r"printf %s '(__SSTERM_CWD_[^']+__)BEGIN__' >&2",
          ).firstMatch(command)?.group(1);
          if (marker == null) throw StateError('missing cwd envelope');
          session.complete(
            stderr: '${marker}BEGIN__/srv/project${marker}END__0123456789',
          );
          return session;
        },
      );

      final result = await executor.executeSsh(
        _UnusedSshClient(),
        '/srv',
        'cd project',
      );

      expect(result.effectiveCwd, '/srv/project');
      expect(result.output, contains('0123'));
      expect(result.output, isNot(contains('456789')));
      expect(result.truncated, isTrue);
    });
  });
}
