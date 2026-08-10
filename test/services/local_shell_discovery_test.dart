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

  test('builds no-launcher WSL arguments with the OSC 7 shell wrapper', () {
    final arguments = buildWslInteractiveShellArguments(
      distro: 'Ubuntu',
      loginShell: '/bin/zsh',
    );

    expect(arguments.take(7), [
      '-d',
      'Ubuntu',
      '--cd',
      '~',
      '--',
      '/bin/sh',
      '-lc',
    ]);
    expect(arguments.last, contains('SHELL=/bin/zsh'));
    expect(arguments.last, contains(']7;file://'));
    expect(arguments.last, isNot(contains(']133;')));
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
    },
    skip: Platform.isWindows ? false : 'Windows-only discovery path',
  );
}
