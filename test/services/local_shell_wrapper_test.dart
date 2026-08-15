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
