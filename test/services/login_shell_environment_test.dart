import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_discovery.dart';
import 'package:ssterm/services/login_shell_environment.dart';

void main() {
  const zsh = LocalShellOption(
    id: 'zsh',
    displayName: 'Zsh',
    executable: '/bin/zsh',
  );

  test('caches a valid PATH by shell executable', () async {
    var calls = 0;
    final resolver = LoginShellEnvironmentResolver(
      readPath: (_) async {
        calls++;
        return '/opt/homebrew/bin:/usr/bin';
      },
    );

    expect(await resolver.resolvePath(zsh), {
      'PATH': '/opt/homebrew/bin:/usr/bin',
    });
    expect(await resolver.resolvePath(zsh), {
      'PATH': '/opt/homebrew/bin:/usr/bin',
    });
    expect(calls, 1);
  });

  test('falls back when the login shell cannot provide a PATH', () async {
    final resolver = LoginShellEnvironmentResolver(readPath: (_) async => null);

    expect(await resolver.resolvePath(zsh), isEmpty);
  });

  test('falls back when the login shell reader fails', () async {
    final resolver = LoginShellEnvironmentResolver(
      readPath: (_) => Future<String?>.error(TimeoutException('timed out')),
    );

    expect(await resolver.resolvePath(zsh), isEmpty);
  });
}
