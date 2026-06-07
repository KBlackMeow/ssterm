import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';

void main() {
  group('buildInteractiveShellWrapper', () {
    late String script;
    setUpAll(() => script = buildInteractiveShellWrapper());

    test('emits OSC 7 to report cwd', () {
      expect(script, contains(r'\033]7;'));
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

    test('installs OSC 133 ; C preexec hook (industry shell-integration protocol)', () {
      expect(script, contains('__ssterm_osc133_preexec'));
      expect(script, contains(r'\033]133;C\007'));
    });

    test('installs OSC 133 ; D precmd hook with exit code', () {
      expect(script, contains('__ssterm_osc133_precmd'));
      expect(script, contains(r'\033]133;D;%s\007'));
    });

    test('precmd hook saves \$? at function entry to survive other hooks', () {
      // Without `local _ssterm_ec=\$?` the printf would see whatever a
      // preceding precmd / PROMPT_COMMAND command left in \$? — which is
      // virtually always 0 once a `case` or `[[ ]]` has run.  Saving on
      // entry guarantees the user command's exit code is preserved.
      expect(script, contains(r'local _ssterm_ec=$?'));
      expect(script, contains(r'printf '"'"r'\033]133;D;%s\007'"'"r' "$_ssterm_ec"'));
    });

    test('zsh wrapper installs both OSC 133 hooks via __ssterm_heal_hooks', () {
      expect(script, contains('__ssterm_heal_hooks'));
      expect(script, contains('preexec_functions+=(__ssterm_osc133_preexec)'));
    });

    test('zsh wrapper places osc133_precmd at index 1 of precmd_functions', () {
      // Ordering invariant: osc133_precmd MUST run first so it sees the
      // user command's \$? before any other hook clobbers it.  We assert
      // both the initial install and the heal-hooks reassertion.
      expect(
        script,
        contains(
          'precmd_functions=(__ssterm_osc133_precmd __ssterm_heal_hooks',
        ),
        reason: 'osc133_precmd must be the first precmd hook on initial install',
      );
      expect(
        script,
        contains(r'"${precmd_functions[1]}" != "__ssterm_osc133_precmd"'),
        reason: 'heal_hooks must re-assert osc133_precmd at index 1',
      );
    });

    test('bash wrapper gates OSC 133 install on bash 4.4+ for PS0 support', () {
      expect(script, contains('BASH_VERSINFO'));
      expect(script, contains(r"PS0='$(__ssterm_osc133_preexec)'"));
    });

    test('exports SSTM_SHELL_BIN so the agent wrapper knows which shell to use', () {
      // The agent wraps multi-line cmds in `\${SSTM_SHELL_BIN:-sh} -c '…'`.
      // Without this export the agent would default to `sh`, losing
      // bash/zsh aliases and arrays inside multi-line bodies.
      expect(script, contains('export SSTM_SHELL_BIN=zsh'));
      expect(script, contains('export SSTM_SHELL_BIN=bash'));
    });
  });
}
