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
  });
}
