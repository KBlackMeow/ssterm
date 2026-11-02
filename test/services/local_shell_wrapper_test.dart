import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';

void main() {
  group('buildInteractiveShellWrapper', () {
    late String script;
    setUpAll(() => script = buildInteractiveShellWrapper());

    test('emits current-directory metadata without input hooks', () {
      final forbiddenOsc = ']${100 + 33};';
      final forbiddenHook = ['__ssterm', 'osc', '${100 + 33}'].join('_');
      expect(script, contains(']7;file://'));
      expect(script, isNot(contains(forbiddenOsc)));
      expect(script, isNot(contains(forbiddenHook)));
      expect(script, isNot(contains('PS0=')));
    });

    test('defines __ssterm_cwd helper function', () {
      expect(script, contains('__ssterm_cwd'));
    });

    test('handles zsh via ZDOTDIR isolation', () {
      expect(script, contains('ZDOTDIR='));
      expect(script, contains('zsh'));
    });

    test('handles bash via ENV fd trick', () {
      expect(script, contains('bash'));
      expect(script, contains('PROMPT_COMMAND'));
    });

    test('handles fish after user configuration with a wrapped prompt', () {
      expect(script, contains('fish)'));
      expect(script, contains('-C'));
      expect(script, contains('functions -c fish_prompt'));
    });

    test('starts fish with its standard terminal capability queries', () {
      expect(localShellStartupArguments('/opt/homebrew/bin/fish'), isEmpty);
      expect(localShellStartupArguments('/bin/zsh'), isEmpty);
      expect(script, isNot(contains('no-query-term')));
    });

    test('macOS visible POSIX shells can launch as login shells', () {
      for (final shell in ['/bin/zsh', '/bin/bash', '/opt/homebrew/bin/fish']) {
        expect(localShellStartupArguments(shell, login: true), ['-l']);
      }
      expect(
        localShellStartupArguments('/usr/local/bin/custom-shell', login: true),
        isEmpty,
      );
      expect(localShellStartupArguments('/bin/zsh'), isEmpty);
    });

    test(
      'system login preserves cwd and environment and starts a login shell',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'ssterm-login-',
        );
        addTearDown(() => directory.delete(recursive: true));
        await File(
          '${directory.path}/.zprofile',
        ).writeAsString('export SSTERM_LOGIN_PROFILE=loaded\n');
        // Avoid loading the developer's interactive plugins in the test.
        await File('${directory.path}/.zshrc').writeAsString('');
        final account = await Process.run('/usr/bin/id', ['-un']);
        expect(account.exitCode, 0);
        final process = await Process.start(
          '/usr/bin/script',
          [
            '-q',
            '/dev/null',
            '/usr/bin/login',
            ...macOsLoginArguments(
              '/bin/zsh',
              user: (account.stdout as String).trim(),
            ),
            '-i',
            '-c',
            r'''[[ -o login ]] || exit 41
[[ "$PWD" -ef "$ZDOTDIR" ]] || exit 42
[[ "$SSTERM_LOGIN_PROFILE" = loaded ]] || exit 43
[[ "$SSTERM_LOGIN_TEST" = preserved ]] || exit 44
printf 'SSTERM_LOGIN_OK\n'
''',
          ],
          workingDirectory: directory.path,
          environment: {
            'ZDOTDIR': directory.path,
            'SSTERM_LOGIN_TEST': 'preserved',
            'TERM': 'xterm-256color',
          },
        );
        addTearDown(() => process.kill());
        await process.stdin.close();
        final output = utf8.decoder.bind(process.stdout).join();
        final errors = utf8.decoder.bind(process.stderr).join();
        expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(await output, contains('SSTERM_LOGIN_OK'));
        expect(await errors, isEmpty);
      },
      skip: !Platform.isMacOS,
    );

    test(
      'rejects unknown shells instead of launching without cwd metadata',
      () {
        expect(script, isNot(contains(r'exec "$shell" -i')));
        expect(script, contains('supports only bash, zsh, and fish'));
      },
    );

    test('does not export the removed Agent shell hint', () {
      final removedHint = ['SSTM', 'SHELL', 'BIN'].join('_');
      expect(script, isNot(contains(removedHint)));
    });

    test('runs fish and reports its initial cwd', () async {
      const fish = '/opt/homebrew/bin/fish';
      if (!File(fish).existsSync()) return;

      final process = await Process.start(
        '/bin/sh',
        ['-c', script],
        environment: {...Platform.environment, 'SHELL': fish},
      );
      process.stdin.writeln('exit');
      await process.stdin.close();
      final stdout = await utf8.decoder.bind(process.stdout).join();
      await process.stderr.drain<void>();

      expect(await process.exitCode, 0);
      expect(stdout, contains('\x1b]7;file://${Directory.current.path}\x1b\\'));
    });
  });
}
