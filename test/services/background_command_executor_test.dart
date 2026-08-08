import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/background_command_executor.dart';
import 'package:ssterm/services/local_shell_discovery.dart';

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

    test('rejects terminal-only shell variants and Windows', () {
      const powershell = LocalShellOption(
        id: 'powershell',
        displayName: 'PowerShell',
        executable: 'powershell.exe',
        usePowerShellWrapper: true,
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
  });

  group('BackgroundCommandExecutor', () {
    const zsh = LocalShellOption(
      id: 'zsh',
      displayName: 'Zsh',
      executable: '/bin/zsh',
    );

    test(
      'returns stdout, stderr, and the shell exit code without a PTY',
      () async {
        final result = await const BackgroundCommandExecutor().executeLocal(
          BackgroundCommandTarget.local(
            shell: zsh,
            cwd: '/tmp',
            platform: BackgroundCommandPlatform.macos,
          ),
          'printf out; printf err >&2; exit 7',
        );

        expect(result.exitCode, 7);
        expect(result.output, contains('[stdout]\nout'));
        expect(result.output, contains('[stderr]\nerr'));
        expect(result.truncated, isFalse);
      },
    );

    test('cancels only the background child command', () async {
      final result = await const BackgroundCommandExecutor(
        timeout: Duration(seconds: 5),
      ).executeLocal(
        BackgroundCommandTarget.local(
          shell: zsh,
          cwd: '/tmp',
          platform: BackgroundCommandPlatform.macos,
        ),
        'sleep 5',
        isCancelled: () => true,
      );

      expect(result.exitCode, isNull);
      expect(result.output, contains('cancelled'));
    });
  });
}
