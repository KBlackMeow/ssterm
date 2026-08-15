import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_discovery.dart';

void main() {
  group('LocalShellOption.usePowerShellCwdWrapper JSON round-trip', () {
    test('round-trips true', () {
      const shell = LocalShellOption(
        id: 'pwsh',
        displayName: 'PowerShell 7',
        executable: r'C:\Program Files\PowerShell\7\pwsh.exe',
        usePowerShellCwdWrapper: true,
      );

      final json = shell.toJson();
      expect(json['usePowerShellCwdWrapper'], true);

      final restored = LocalShellOption.fromJson(json)!;
      expect(restored.usePowerShellCwdWrapper, true);
    });

    test('omits the key when false, and defaults to false on decode', () {
      const shell = LocalShellOption(
        id: 'cmd',
        displayName: 'CMD',
        executable: r'C:\Windows\System32\cmd.exe',
      );

      final json = shell.toJson();
      expect(json.containsKey('usePowerShellCwdWrapper'), isFalse);

      final restored = LocalShellOption.fromJson(json)!;
      expect(restored.usePowerShellCwdWrapper, false);
    });

    test('reads the legacy wrapper key and writes the cwd-wrapper key', () {
      final restored = LocalShellOption.fromJson({
        'id': 'powershell',
        'displayName': 'Windows PowerShell',
        'executable':
            r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        'usePowerShellWrapper': true,
      })!;

      expect(restored.usePowerShellCwdWrapper, isTrue);
      expect(restored.toJson(), containsPair('usePowerShellCwdWrapper', true));
      expect(restored.toJson().containsKey('usePowerShellWrapper'), isFalse);
    });
  });

  test(
    'structuralEquals distinguishes shells that only differ by usePowerShellCwdWrapper',
    () {
      const a = LocalShellOption(
        id: 'powershell',
        displayName: 'PowerShell',
        executable: r'C:\powershell.exe',
        usePowerShellCwdWrapper: false,
      );
      const b = LocalShellOption(
        id: 'powershell',
        displayName: 'PowerShell',
        executable: r'C:\powershell.exe',
        usePowerShellCwdWrapper: true,
      );

      expect(a.structuralEquals(b), isFalse);
    },
  );

  test('selects a no-launcher WSL distro without shell arguments', () {
    final arguments = buildWslInteractiveShellArguments(distro: 'Ubuntu');

    expect(arguments, ['-d', 'Ubuntu']);
  });

  test('starts a launcher-backed WSL distro without injected commands', () {
    expect(buildWslLauncherArguments(), isEmpty);
  });

  test('migrates a cached launcher-backed WSL bootstrap to 1.6 behavior', () {
    final shell = LocalShellOption.fromJson({
      'id': 'wsl:Ubuntu',
      'displayName': 'Ubuntu',
      'executable':
          r'C:\Users\Alice\AppData\Local\Microsoft\WindowsApps\ubuntu.exe',
      'arguments': [
        'run',
        '/bin/sh',
        '-lc',
        'script',
        'ssterm-wsl',
        '/bin/bash',
      ],
      'isWsl': true,
    })!;

    expect(shell.arguments, isEmpty);
  });

  test('migrates a cached wsl.exe bootstrap to a direct login shell', () {
    final shell = LocalShellOption.fromJson({
      'id': 'wsl:Ubuntu',
      'displayName': 'WSL Ubuntu',
      'executable': r'C:\Windows\System32\wsl.exe',
      'arguments': [
        '-d',
        'Ubuntu',
        '--',
        '/bin/sh',
        '-lc',
        'script',
        'ssterm-wsl',
        '/bin/bash',
      ],
      'isWsl': true,
    })!;

    expect(shell.arguments, ['-d', 'Ubuntu']);
  });

  test('only bash and zsh qualify for OSC 7 POSIX shell discovery', () {
    expect(isOsc7CompatiblePosixShellPath('/bin/bash'), isTrue);
    expect(isOsc7CompatiblePosixShellPath('/usr/local/bin/zsh'), isTrue);
    for (final path in const [
      '/bin/sh',
      '/usr/bin/fish',
      '/bin/tcsh',
      '/bin/ksh',
    ]) {
      expect(isOsc7CompatiblePosixShellPath(path), isFalse, reason: path);
    }
  });

  test('maps Git Bash MSYS cwd paths to native Windows paths', () {
    const shell = LocalShellOption(
      id: 'git-bash',
      displayName: 'Git Bash',
      executable: r'C:\Program Files\Git\usr\bin\env.exe',
    );

    expect(
      nativePathForLocalShell(shell, '/c/Users/Alice/project'),
      r'C:\Users\Alice\project',
    );
    expect(
      nativePathForLocalShell(shell, '/home/Alice'),
      r'C:\Program Files\Git\home\Alice',
    );
    expect(
      nativePathForLocalShell(shell, '//server/share/project'),
      r'\\server\share\project',
    );
  });

  group(
    'LocalShellDiscovery.discoverSync on Windows',
    () {
      late List<LocalShellOption> shells;
      setUpAll(() => shells = LocalShellDiscovery.discoverSync());

      LocalShellOption? byId(String id) {
        for (final s in shells) {
          if (s.id == id) return s;
        }
        return null;
      }

      test('powershell/pwsh candidates opt into the OSC 7 prelude', () {
        for (final id in const ['powershell', 'pwsh', 'pwsh-x86']) {
          final shell = byId(id);
          if (shell == null) continue; // not installed on this machine
          expect(
            shell.usePowerShellCwdWrapper,
            isTrue,
            reason: '$id should use the PowerShell OSC 7 wrapper',
          );
        }
      });

      test('cmd does not opt into the PowerShell OSC 7 prelude', () {
        final cmd = byId('cmd');
        expect(cmd, isNotNull);
        expect(cmd!.usePowerShellCwdWrapper, isFalse);
      });

      test('git-bash candidates do not opt into the PowerShell prelude', () {
        for (final id in const ['git-bash', 'git-bash-x86']) {
          final shell = byId(id);
          if (shell == null) continue; // not installed on this machine
          expect(shell.usePowerShellCwdWrapper, isFalse);
        }
      });

      test(
        'native shell processes are discovered without startup arguments',
        () {
          for (final shell in shells) {
            expect(shell.arguments, isEmpty, reason: shell.id);
          }
        },
      );
    },
    skip: Platform.isWindows ? false : 'Windows-only discovery path',
  );
}
