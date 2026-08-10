import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/powershell_shell_wrapper.dart';

void main() {
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
      expect(script, contains('file:///'));
      expect(script, isNot(contains('PSReadLine')));
      expect(script, isNot(contains('Set-PSReadLineKeyHandler')));
    });

    test('has no execution-policy or on-disk script dependency', () {
      expect(script, isNot(contains('Set-ExecutionPolicy')));
      expect(script, isNot(contains('.ps1')));
    });
  });
}
