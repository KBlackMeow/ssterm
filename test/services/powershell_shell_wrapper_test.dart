import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/powershell_shell_wrapper.dart';

void main() {
  group('isPowerShellEncodedCommandPolicyError', () {
    test('recognizes the Windows policy error that blocks encoded startup', () {
      expect(
        isPowerShellEncodedCommandPolicyError(
          'CreateProcessW failed (Windows error 786: access restricted)',
        ),
        isTrue,
      );
    });

    test('does not retry unrelated PowerShell startup errors', () {
      expect(
        isPowerShellEncodedCommandPolicyError(
          'CreateProcessW failed (Windows error 267: invalid directory)',
        ),
        isFalse,
      );
    });
  });

  group('buildPowerShellOsc7Prelude', () {
    late String script;
    setUpAll(() => script = buildPowerShellOsc7Prelude());

    test(
      'chains to the previously-defined prompt function rather than clobbering it',
      () {
        expect(script, contains('SstmPrevPrompt'));
        expect(script, contains(r'$function:prompt'));
      },
    );

    test('emits cwd metadata without modifying input handling', () {
      final forbiddenOsc = '${100 + 33};';
      expect(script, contains('file:///'));
      expect(script, isNot(contains(forbiddenOsc)));
      expect(script, isNot(contains('PSReadLine')));
      expect(script, isNot(contains('Set-PSReadLineKeyHandler')));
    });

    test('has no execution-policy or on-disk script dependency', () {
      expect(script, isNot(contains('Set-ExecutionPolicy')));
      expect(script, isNot(contains('.ps1')));
    });
  });
}
