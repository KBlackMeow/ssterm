import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/powershell_shell_wrapper.dart';

void main() {
  group('buildPowerShellOsc133Prelude', () {
    late String script;
    setUpAll(() => script = buildPowerShellOsc133Prelude());

    test('hooks Enter via PSReadLine for the command-start marker', () {
      expect(script, contains('Set-PSReadLineKeyHandler'));
      expect(script, contains('-Chord Enter'));
    });

    test('chains to the previously-bound Enter handler rather than clobbering it', () {
      expect(script, contains('SstmPrevEnterFn'));
      expect(script, contains('AcceptLine'));
    });

    test('chains to the previously-defined prompt function rather than clobbering it', () {
      expect(script, contains('SstmPrevPrompt'));
      expect(script, contains(r'$function:prompt'));
    });

    test('gates the D marker on OSC133 having actually installed', () {
      // A lone D with no matching C would permanently (and wrongly) flip
      // hasOsc133 true with C never arriving — this flag must guard the D
      // emission specifically, not just be present somewhere in the script.
      expect(script, contains('SstmOsc133Enabled'));
    });

    test('emits OSC 133 ; C and ; D using [char] escapes, not backtick escapes', () {
      // `` `e `` (escape) isn't recognized by Windows PowerShell 5.1; the
      // explicit [char] form works on both 5.1 and 7.
      expect(script, contains('133;C'));
      expect(script, contains('133;D;'));
      expect(script, contains('[char]27'));
      expect(script, contains('[char]7'));
      expect(script, isNot(contains('`e')));
    });

    test('reports cwd via triple-slash OSC 7 so the drive letter survives parsing', () {
      // RemoteCwdParser's file://<host>/<path> matcher treats everything up
      // to the first `/` as the host; a two-slash file://C:/Users/foo would
      // swallow the drive letter into the discarded host component.
      expect(script, contains('file:///'));
    });

    test(r'uses the unified $?/$LASTEXITCODE exit-code idiom', () {
      expect(script, contains(r'$?'));
      expect(script, contains(r'$LASTEXITCODE'));
      expect(script, contains('[int]'));
    });

    test('wraps PSReadLine setup in try/catch to degrade gracefully', () {
      expect(script, contains('try {'));
      expect(script, contains('catch {'));
      expect(script, contains('Get-Module'));
      expect(script, contains('PSReadLine'));
    });

    test('has no execution-policy or on-disk script dependency', () {
      expect(script, isNot(contains('Set-ExecutionPolicy')));
      expect(script, isNot(contains('.ps1')));
    });
  });
}
