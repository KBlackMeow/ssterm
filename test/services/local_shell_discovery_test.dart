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

  test('bash, zsh, and fish qualify for OSC 7 POSIX shell discovery', () {
    expect(isOsc7CompatiblePosixShellPath('/bin/bash'), isTrue);
    expect(isOsc7CompatiblePosixShellPath('/usr/local/bin/zsh'), isTrue);
    expect(isOsc7CompatiblePosixShellPath('/opt/homebrew/bin/fish'), isTrue);
    for (final path in const ['/bin/sh', '/bin/tcsh', '/bin/ksh']) {
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

  group('LocalShellDiscovery.isLaunchableExecutable', () {
    test('accepts a WindowsApps alias that PATH resolves to itself', () {
      // App execution aliases are reparse points File.existsSync cannot see;
      // WSL distro launchers are aliases, so PATH identity must accept them
      // (case-insensitively — `where` output casing varies).
      const alias =
          r'C:\Users\alice\AppData\Local\Microsoft\WindowsApps\ubuntu.exe';
      expect(
        LocalShellDiscovery.isLaunchableExecutable(
          executable: alias,
          fileExists: (_) => false,
          resolveOnPath: (name) =>
              name == 'ubuntu.exe' ? alias.toUpperCase() : null,
        ),
        isTrue,
      );
    });

    test('rejects an absent fixed path whose name resolves elsewhere', () {
      // Launched from Git Bash, `where bash.exe` finds the x64 install; the
      // x86 candidate must not ride that resolution.
      expect(
        LocalShellDiscovery.isLaunchableExecutable(
          executable: r'C:\Program Files (x86)\Git\bin\bash.exe',
          fileExists: (_) => false,
          resolveOnPath: (name) => name == 'bash.exe'
              ? r'C:\Program Files\Git\usr\bin\bash.exe'
              : null,
        ),
        isFalse,
      );
    });

    test('rejects an absent absolute path with no PATH resolution', () {
      expect(
        LocalShellDiscovery.isLaunchableExecutable(
          executable: r'C:\Program Files (x86)\PowerShell\7\pwsh.exe',
          fileExists: (_) => false,
          resolveOnPath: (_) => null,
        ),
        isFalse,
      );
    });

    test('keeps the bare-name PATH fallback for real files', () {
      expect(
        LocalShellDiscovery.isLaunchableExecutable(
          executable: 'wsl.exe',
          fileExists: (_) => false,
          resolveOnPath: (name) => name == 'wsl.exe'
              ? r'C:\Windows\System32\wsl.exe'
              : null,
        ),
        isTrue,
      );
    });

    test('existing files pass without probing PATH', () {
      expect(
        LocalShellDiscovery.isLaunchableExecutable(
          executable: r'C:\Windows\System32\wsl.exe',
          fileExists: (_) => true,
          resolveOnPath: (_) => throw StateError('must not probe PATH'),
        ),
        isTrue,
      );
    });
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

      test('absent fixed-path candidates are not validated via PATH', () {
        // Launched from Git Bash, `where bash.exe` resolves the x64 install;
        // that must not let the (x86) fixed-path candidate masquerade as an
        // installed shell when its own path does not exist.
        if (!File(r'C:\Program Files (x86)\Git\bin\bash.exe').existsSync()) {
          expect(byId('git-bash-x86'), isNull);
        }
        for (final shell in shells.where((s) => !s.isWsl)) {
          expect(
            File(shell.executable).existsSync(),
            isTrue,
            reason: '${shell.id} -> ${shell.executable}',
          );
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
