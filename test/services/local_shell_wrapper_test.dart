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

    test(
      'rejects unknown shells instead of launching without cwd metadata',
      () {
        expect(script, isNot(contains(r'exec "$shell" -i')));
        expect(script, contains('supports only bash and zsh'));
      },
    );

    test('does not export the removed Agent shell hint', () {
      final removedHint = ['SSTM', 'SHELL', 'BIN'].join('_');
      expect(script, isNot(contains(removedHint)));
    });
  });
}
