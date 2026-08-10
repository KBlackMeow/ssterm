import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';
import 'package:ssterm/services/ssh_connection.dart';

void main() {
  test('SSH bootstrap reports cwd without legacy command-boundary hooks', () {
    final script = interactiveShellWrapperCommand();
    final forbiddenOsc = ']${100 + 33};';
    final forbiddenHook = ['__ssterm', 'osc', '${100 + 33}'].join('_');

    expect(script, contains(']7;file://'));
    expect(script, isNot(contains(forbiddenOsc)));
    expect(script, isNot(contains(forbiddenHook)));
    expect(script, isNot(contains('PS0=')));
  });

  test('SSH bootstrap rejects shells without a supported cwd hook', () {
    final script = interactiveShellWrapperCommand();
    expect(script, isNot(contains(r'exec "$shell" -il')));
    expect(script, contains('supports only bash and zsh'));
  });

  test('WSL launcher wrapper reports cwd without command-boundary hooks', () {
    final script = buildInteractiveShellWrapper();
    final forbiddenOsc = ']${100 + 33};';
    expect(script, contains(']7;file://'));
    expect(script, isNot(contains(forbiddenOsc)));
  });
}
