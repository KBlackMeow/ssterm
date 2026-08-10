import 'dart:io';

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
      'cancels only the background child command',
      () async {
        final result =
            await const BackgroundCommandExecutor(
              timeout: Duration(seconds: 5),
            ).executeLocal(
              BackgroundCommandTarget.local(
                shell: zsh,
                cwd: Directory.current.path,
                platform: BackgroundCommandPlatform.macos,
              ),
              'sleep 5',
              isCancelled: () => true,
            );

        expect(result.exitCode, isNull);
        expect(result.output, contains('cancelled'));
      },
      skip: Platform.isWindows
          ? 'Covered by tool/windows_background_smoke.dart with the packaged DLL.'
          : false,
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
  });
}
