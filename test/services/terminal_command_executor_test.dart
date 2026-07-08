import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/services/terminal_command_executor.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalCommandExecutor.prepareCommand', () {
    const executor = TerminalCommandExecutor();

    test('preserves a single-line command', () {
      expect(executor.prepareCommand('git status'), 'git status');
    });

    test('preserves legacy multiline wrapping for trailing newlines', () {
      expect(
        executor.prepareCommand('pwd\n\n'),
        startsWith(r"${SSTM_SHELL_BIN:-sh} -c '"),
      );
    });

    test('wraps multiline commands as one shell command', () {
      final prepared = executor.prepareCommand("printf 'a'\nprintf 'b'");

      expect(prepared, startsWith(r"${SSTM_SHELL_BIN:-sh} -c '"));
      expect(prepared, contains(r"'\''"));
      expect(prepared, endsWith("'"));
      expect(prepared, contains('\n'));
    });
  });

  test('CommandExecutionTarget keeps command and raw senders together', () {
    final commands = <String>[];
    final raw = <Uint8List>[];
    final target = CommandExecutionTarget(
      terminal: Terminal(),
      outputPipe: null,
      sendCommand: commands.add,
      sendRaw: raw.add,
    );

    target.sendCommand('date');
    target.sendRaw(Uint8List.fromList([3]));

    expect(commands, ['date']);
    expect(raw.single, [3]);
  });

  test(
    'execute blocks commands while the target uses the alternate screen',
    () async {
      final terminal = Terminal()..useAltBuffer();
      final commands = <String>[];
      final target = CommandExecutionTarget(
        terminal: terminal,
        outputPipe: null,
        sendCommand: commands.add,
        sendRaw: (_) {},
      );

      final result = await const TerminalCommandExecutor().execute(
        target,
        'pwd',
      );

      expect(commands, isEmpty);
      expect(result?.output, contains('alternate-screen'));
    },
  );

  test('execute captures OSC 133 output and exit code', () async {
    final terminal = Terminal();
    final pipe = OutputPipe(terminal);
    final output = StreamController<List<int>>();
    pipe.bind(output.stream);
    output.add(utf8.encode('\x1b]133;D;0\x07'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final commands = <String>[];
    final target = CommandExecutionTarget(
      terminal: terminal,
      outputPipe: pipe,
      sendCommand: (command) {
        commands.add(command);
        output.add(utf8.encode('\x1b]133;C\x07hello\x1b]133;D;7\x07'));
      },
      sendRaw: (_) {},
    );

    final result = await const TerminalCommandExecutor().execute(
      target,
      'printf hello',
    );

    expect(commands, ['printf hello']);
    expect(result?.output, 'hello');
    expect(result?.exitCode, 7);

    pipe.dispose();
    await output.close();
  });

  test('execute sends Ctrl-C after an OSC 133 timeout', () async {
    final terminal = Terminal();
    final pipe = OutputPipe(terminal);
    final output = StreamController<List<int>>();
    pipe.bind(output.stream);
    output.add(utf8.encode('\x1b]133;D;0\x07'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final raw = <Uint8List>[];
    final target = CommandExecutionTarget(
      terminal: terminal,
      outputPipe: pipe,
      sendCommand: (_) {},
      sendRaw: raw.add,
    );
    const executor = TerminalCommandExecutor(
      oscTimeout: Duration(milliseconds: 10),
      recoveryTimeout: Duration(milliseconds: 10),
    );

    final result = await executor.execute(target, 'sleep 10');

    expect(raw.single, [3]);
    expect(result?.output, contains('Ctrl-C was sent'));

    pipe.dispose();
    await output.close();
  });

  test('execute reads an exit code from the sentinel fallback', () async {
    final terminal = Terminal();
    terminal.write(List.filled(20, '\r\n').join());
    final commands = <String>[];
    final target = CommandExecutionTarget(
      terminal: terminal,
      outputPipe: null,
      sendCommand: (command) {
        commands.add(command);
        final marker = RegExp(r'(__SSTM_\d+__)').firstMatch(command)!.group(1)!;
        terminal.write('\r\n$marker:3\r\n');
      },
      sendRaw: (_) {},
    );
    const executor = TerminalCommandExecutor(
      pollInterval: Duration(milliseconds: 1),
      fallbackTimeout: Duration(milliseconds: 20),
    );

    final result = await executor.execute(target, 'false');

    expect(commands.single, contains('__ssterm_ec'));
    expect(result?.exitCode, 3);
  });
}
