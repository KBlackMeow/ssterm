import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';

void main() {
  group('buildInteractiveShellWrapper', () {
    late String script;
    setUpAll(() => script = buildInteractiveShellWrapper());

    test('emits current-directory metadata without input hooks', () {
      expect(script, contains(']7;file://'));
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

    test('falls back to exec shell -i for unknown shells', () {
      expect(script, contains(r'exec "$shell" -i'));
    });

    test(
      'exports SSTM_SHELL_BIN so the agent wrapper knows which shell to use',
      () {
        // The agent wraps multi-line cmds in `\${SSTM_SHELL_BIN:-sh} -c '…'`.
        // Without this export the agent would default to `sh`, losing
        // bash/zsh aliases and arrays inside multi-line bodies.
        expect(script, contains('export SSTM_SHELL_BIN=zsh'));
        expect(script, contains('export SSTM_SHELL_BIN=bash'));
      },
    );
  });
}
