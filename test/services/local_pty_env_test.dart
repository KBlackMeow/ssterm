import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_discovery.dart';
import 'package:ssterm/services/login_shell_environment.dart';
import 'package:ssterm/services/local_pty_service.dart';

void main() {
  test('CMD prompt reports cwd without a startup command', () {
    expect(buildCmdOsc7Prompt(null), r'$E]7;file:///$P$E\$P$G');
    expect(buildCmdOsc7Prompt(r'$N$G'), r'$E]7;file:///$P$E\$N$G');
  });

  group('buildWslEnvironment', () {
    test('always sets TERM to xterm-256color', () {
      final env = buildWslEnvironment(systemRoot: r'C:\Windows');
      expect(env['TERM'], equals('xterm-256color'));
    });

    test('always sets COLORTERM to truecolor', () {
      final env = buildWslEnvironment(systemRoot: r'C:\Windows');
      expect(env['COLORTERM'], equals('truecolor'));
    });

    test('WSLENV is empty string to prevent Windows var translation', () {
      final env = buildWslEnvironment(systemRoot: r'C:\Windows');
      expect(env['WSLENV'], equals(''));
    });

    test('PATH contains only Windows system directories, no Linux paths', () {
      final env = buildWslEnvironment(systemRoot: r'C:\Windows');
      final path = env['PATH']!;
      expect(path, contains(r'C:\Windows\System32'));
      expect(path, isNot(contains('/usr/bin')));
      expect(path, isNot(contains('/bin')));
    });

    test('optional extras are merged when provided', () {
      final env = buildWslEnvironment(
        systemRoot: r'C:\Windows',
        extras: {'USERNAME': 'alice', 'TEMP': r'C:\Temp'},
      );
      expect(env['USERNAME'], equals('alice'));
      expect(env['TEMP'], equals(r'C:\Temp'));
    });
  });

  group('buildGitBashEnvironment', () {
    test('always sets TERM to xterm-256color', () {
      final env = buildGitBashEnvironment(
        executable: r'C:\Git\usr\bin\env.exe',
        systemRoot: r'C:\Windows',
      );
      expect(env['TERM'], equals('xterm-256color'));
    });

    test('sets MSYSTEM to MINGW64', () {
      final env = buildGitBashEnvironment(
        executable: r'C:\Git\usr\bin\env.exe',
        systemRoot: r'C:\Windows',
      );
      expect(env['MSYSTEM'], equals('MINGW64'));
    });

    test('PATH includes Git usr/bin derived from executable path', () {
      final env = buildGitBashEnvironment(
        executable: r'C:\Git\usr\bin\env.exe',
        systemRoot: r'C:\Windows',
      );
      expect(env['PATH'], contains(r'C:\Git\usr\bin'));
    });

    test('SHELL is always /usr/bin/bash', () {
      final env = buildGitBashEnvironment(
        executable: r'C:\Git\usr\bin\env.exe',
        systemRoot: r'C:\Windows',
      );
      expect(env['SHELL'], equals('/usr/bin/bash'));
    });

    test('extras override defaults', () {
      final env = buildGitBashEnvironment(
        executable: r'C:\Git\usr\bin\env.exe',
        systemRoot: r'C:\Windows',
        extras: {'CUSTOM_VAR': 'yes'},
      );
      expect(env['CUSTOM_VAR'], equals('yes'));
    });
  });

  group('buildLocalShellEnvironment', () {
    test('always sets TERM, COLORTERM, TERM_PROGRAM', () {
      final env = buildLocalShellEnvironment();
      expect(env['TERM'], equals('xterm-256color'));
      expect(env['COLORTERM'], equals('truecolor'));
      expect(env['TERM_PROGRAM'], equals('ssterm'));
    });

    test('merges extra env vars', () {
      final env = buildLocalShellEnvironment(extras: {'FOO': 'bar'});
      expect(env['FOO'], equals('bar'));
    });

    test('uses the selected shell login PATH over a GUI process PATH', () async {
      const fish = LocalShellOption(
        id: 'fish',
        displayName: 'Fish',
        executable: '/opt/homebrew/bin/fish',
      );
      final resolver = LoginShellEnvironmentResolver(
        readPath: (_) async => '/opt/homebrew/bin:/usr/bin:/bin',
      );

      final env = await buildLocalShellEnvironmentWithLoginPath(
        shell: fish,
        base: {'PATH': '/usr/bin:/bin'},
        loginEnvironmentResolver: resolver,
      );

      expect(env['PATH'], '/opt/homebrew/bin:/usr/bin:/bin');
      expect(env['TERM'], 'xterm-256color');
    });
  });
}
