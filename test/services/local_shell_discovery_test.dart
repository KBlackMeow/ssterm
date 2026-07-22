import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_discovery.dart';

void main() {
  group('LocalShellOption.usePowerShellWrapper JSON round-trip', () {
    test('round-trips true', () {
      const shell = LocalShellOption(
        id: 'pwsh',
        displayName: 'PowerShell 7',
        executable: r'C:\Program Files\PowerShell\7\pwsh.exe',
        usePowerShellWrapper: true,
      );

      final json = shell.toJson();
      expect(json['usePowerShellWrapper'], true);

      final restored = LocalShellOption.fromJson(json)!;
      expect(restored.usePowerShellWrapper, true);
    });

    test('omits the key when false, and defaults to false on decode', () {
      const shell = LocalShellOption(
        id: 'cmd',
        displayName: 'CMD',
        executable: r'C:\Windows\System32\cmd.exe',
      );

      final json = shell.toJson();
      expect(json.containsKey('usePowerShellWrapper'), isFalse);

      final restored = LocalShellOption.fromJson(json)!;
      expect(restored.usePowerShellWrapper, false);
    });
  });

  test('structuralEquals distinguishes shells that only differ by usePowerShellWrapper', () {
    const a = LocalShellOption(
      id: 'powershell',
      displayName: 'PowerShell',
      executable: r'C:\powershell.exe',
      usePowerShellWrapper: false,
    );
    const b = LocalShellOption(
      id: 'powershell',
      displayName: 'PowerShell',
      executable: r'C:\powershell.exe',
      usePowerShellWrapper: true,
    );

    expect(a.structuralEquals(b), isFalse);
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

      test('powershell/pwsh candidates opt into the OSC133 prelude', () {
        for (final id in const ['powershell', 'pwsh', 'pwsh-x86']) {
          final shell = byId(id);
          if (shell == null) continue; // not installed on this machine
          expect(
            shell.usePowerShellWrapper,
            isTrue,
            reason: '$id should use the PowerShell OSC133 wrapper',
          );
        }
      });

      test('cmd does not opt into the PowerShell OSC133 prelude', () {
        final cmd = byId('cmd');
        expect(cmd, isNotNull);
        expect(cmd!.usePowerShellWrapper, isFalse);
      });

      test('git-bash candidates do not opt into the PowerShell prelude', () {
        for (final id in const ['git-bash', 'git-bash-x86']) {
          final shell = byId(id);
          if (shell == null) continue; // not installed on this machine
          expect(shell.usePowerShellWrapper, isFalse);
        }
      });
    },
    skip: Platform.isWindows ? false : 'Windows-only discovery path',
  );
}
