import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/local_shell_wrapper.dart';
import 'package:ssterm/services/ssh_shell_integration.dart';

void main() {
  for (final echoed in [false, true]) {
    for (final enter in ['', '\r\r\n']) {
      test(
        'SSH startup removes transient prompt across packets (echo=$echoed, enter=${enter.length})',
        () async {
          final integration = SshShellIntegration(token: 'fixture');
          const banner = 'Welcome to Ubuntu\r\n系统状态\r\n\r\n';
          const firstPrompt = '\x1b[32mfixture> \x1b[0m';
          const metadata = '\x1b]3008;type=command\x1b\\';
          const prompt = '\r\x1b[2K\x1b]7;file:///home/test\x1b\\fixture> ';
          final startup = echoed ? integration.command() : enter;
          final input = utf8.encode(
            '$banner$firstPrompt$startup$metadata'
            '\x1b]777;ssterm-start;fixture;prompt\x07hidden startup output'
            '\x1b]777;ssterm-end;fixture\x07$prompt',
          );
          for (var split = 0; split <= input.length; split++) {
            final output =
                await Stream.fromIterable([
                      Uint8List.fromList(input.sublist(0, split)),
                      Uint8List.fromList(input.sublist(split)),
                    ])
                    .transform(integration.outputTransformer)
                    .expand((bytes) => bytes)
                    .toList();
            expect(
              utf8.decode(output),
              '$banner$prompt',
              reason: 'split=$split',
            );
          }
          final output =
              await Stream.fromIterable(
                    input.map((byte) => Uint8List.fromList([byte])),
                  )
                  .transform(integration.outputTransformer)
                  .expand((bytes) => bytes)
                  .toList();
          expect(utf8.decode(output), '$banner$prompt');
        },
      );
    }
  }

  for (final enter in ['', '\r\r\n']) {
    test(
      'empty PS1 preserves the last login line (enter=${enter.length})',
      () async {
        final integration = SshShellIntegration(token: 'fixture');
        const banner = 'Welcome\r\nLast login: fixture\r\n';
        final bytes = utf8.encode(
          '$banner$enter\x1b]777;ssterm-start;fixture;\x07'
          '\x1b]777;ssterm-end;fixture\x07ready',
        );
        final output =
            await Stream.fromIterable(
                  bytes.map((byte) => Uint8List.fromList([byte])),
                )
                .transform(integration.outputTransformer)
                .expand((bytes) => bytes)
                .toList();
        expect(utf8.decode(output), '${banner}ready');
      },
    );
  }

  test('startup EOF preserves login errors before initialization', () async {
    final integration = SshShellIntegration(token: 'fixture');
    final input = utf8.encode('Account unavailable\r\n');
    final output = await Stream.value(Uint8List.fromList(input))
        .transform(integration.outputTransformer)
        .expand((bytes) => bytes)
        .toList();
    expect(output, input);
  });

  test(
    'incomplete startup is reported rather than silently discarded',
    () async {
      final integration = SshShellIntegration(token: 'fixture');
      final input = utf8.encode(
        'Welcome\r\n\x1b]777;ssterm-start;fixture;\x07startup failed',
      );
      final output = await Stream.value(Uint8List.fromList(input))
          .transform(integration.outputTransformer)
          .expand((bytes) => bytes)
          .toList();
      expect(utf8.decode(output), startsWith('Welcome\r\n'));
      expect(utf8.decode(output), contains('shell integration did not finish'));
    },
  );

  test('WSL launcher wrapper reports cwd without command-boundary hooks', () {
    final script = buildInteractiveShellWrapper();
    final forbiddenOsc = ']${100 + 33};';
    expect(script, contains(']7;file://'));
    expect(script, isNot(contains(forbiddenOsc)));
  });
}
