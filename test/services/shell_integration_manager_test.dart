import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/shell_integration_manager.dart';

void main() {
  const block = 'integration body';

  test(
    'installs a marked block without replacing existing profile content',
    () {
      final result = upsertShellIntegrationBlock('user setup\n', block);

      expect(result, startsWith('user setup\n'));
      expect(result, contains('# >>> SSTerm Shell Integration v1 >>>'));
      expect(result, contains(block));
      expect(result, contains('# <<< SSTerm Shell Integration v1 <<<'));
    },
  );

  test('installation is idempotent and upgrades the existing block', () {
    final first = upsertShellIntegrationBlock('', 'old body');
    final second = upsertShellIntegrationBlock(first, 'new body');

    expect(RegExp(r'>>> SSTerm').allMatches(second), hasLength(1));
    expect(second, contains('new body'));
    expect(second, isNot(contains('old body')));
  });

  test('installation and uninstall preserve CRLF line endings', () {
    final installed = upsertShellIntegrationBlock('first\r\nsecond\r\n', block);

    expect(installed.replaceAll('\r\n', ''), isNot(contains('\n')));
    final removed = removeShellIntegrationBlock(installed);
    expect(removed.replaceAll('\r\n', ''), isNot(contains('\n')));
  });

  test('profile codec preserves UTF-8 BOM', () {
    final original = <int>[0xef, 0xbb, 0xbf, ...utf8.encode('old')];
    final encoded = encodeProfileContent('new', original);

    expect(encoded.take(3), [0xef, 0xbb, 0xbf]);
    expect(decodeProfileBytes(encoded), 'new');
  });

  test('profile codec preserves UTF-16LE BOM', () {
    final original = <int>[0xff, 0xfe, 0x6f, 0, 0x6c, 0, 0x64, 0];
    final encoded = encodeProfileContent('新内容', original);

    expect(encoded.take(2), [0xff, 0xfe]);
    expect(decodeProfileBytes(encoded), '新内容');
  });

  test('parses redirected Windows Documents registry value', () {
    const output = '''
    Personal    REG_EXPAND_SZ    %USERPROFILE%\\OneDrive\\Documents
''';

    expect(
      parseWindowsRegistryValue(output),
      r'%USERPROFILE%\OneDrive\Documents',
    );
  });

  test('uninstall preserves user profile content', () {
    final installed = upsertShellIntegrationBlock('before\nafter\n', block);
    final result = removeShellIntegrationBlock(installed);

    expect(result, contains('before'));
    expect(result, contains('after'));
    expect(result, isNot(contains('SSTerm Shell Integration')));
  });

  test('damaged marker blocks are rejected', () {
    expect(
      () => upsertShellIntegrationBlock(
        '# >>> SSTerm Shell Integration v1 >>>\nbroken',
        block,
      ),
      throwsFormatException,
    );
  });

  test('repair replaces an incomplete marker block', () {
    final result = repairShellIntegrationBlock(
      'user setup\n# >>> SSTerm Shell Integration v1 >>>\nbroken',
      block,
    );

    expect(result, contains('user setup'));
    expect(RegExp(r'>>> SSTerm').allMatches(result), hasLength(1));
    expect(result, contains(block));
    expect(result, isNot(contains('broken')));
  });

  test('decodes UTF-16LE WSL diagnostics without mojibake', () {
    const message = 'Access denied: 拒绝访问';
    final bytes = <int>[0xff, 0xfe];
    for (final unit in message.codeUnits) {
      bytes.add(unit & 0xff);
      bytes.add(unit >> 8);
    }

    expect(decodeWslProcessOutput(bytes), message);
  });

  test('decodes a UTF-16LE distro list without relying on a BOM', () {
    const message = '开发环境\r\n';
    final bytes = <int>[];
    for (final unit in message.codeUnits) {
      bytes.add(unit & 0xff);
      bytes.add(unit >> 8);
    }

    expect(decodeWslProcessOutput(bytes, assumeUtf16Le: true), message);
  });

  test('WSL profile targets never infer a profile from an unknown shell', () {
    const target = ShellIntegrationTarget(
      id: 'wsl:test',
      label: 'WSL test',
      kind: ShellIntegrationKind.wslBash,
      state: ShellIntegrationState.unavailable,
      message: 'The default WSL login shell is /bin/fish.',
    );

    expect(target.profilePath, isNull);
    expect(target.state, ShellIntegrationState.unavailable);
  });

  test('fish profile integration emits cwd at every prompt', () {
    final block = shellIntegrationBlockFor(ShellIntegrationKind.fish);

    expect(block, contains('fish_prompt'));
    expect(block, contains(']7;file://'));
  });

  test('WSL profile probe ignores unrelated output before its marker', () {
    final profile = parseWslProfileProbe(
      'welcome message\nwarning\n__SSTERM_PROFILE__\t/home/alice\t/bin/bash\n',
    );

    expect(profile.home, '/home/alice');
    expect(profile.shell, '/bin/bash');
  });

  test('WSL profile probe rejects missing structured output', () {
    expect(() => parseWslProfileProbe('welcome only'), throwsStateError);
  });
}
