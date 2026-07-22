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

    test(
      'cmd dialect sends multiline commands unwrapped but normalizes '
      'line separators to CR',
      () {
        // Not wrapped into a nested invocation (unlike posix/powershell)
        // — but LF alone doesn't submit a line on the classic Windows
        // console line-input mode backing cmd.exe, so embedded newlines
        // must become CR for each line to actually execute in turn.
        final prepared = executor.prepareCommand(
          'cd foo\ndir',
          dialect: CommandSentinelDialect.cmd,
        );

        expect(prepared, 'cd foo\rdir');
      },
    );

    test('powershell dialect wraps multiline commands as one nested '
        'invocation whose payload round-trips', () {
      const script = "Write-Host 'a'\nWrite-Host 'b'";
      final prepared = executor.prepareCommand(
        script,
        dialect: CommandSentinelDialect.powershell,
      );

      expect(
        prepared,
        startsWith('powershell -NoProfile -NonInteractive -EncodedCommand '),
      );
      final encoded = prepared.split(' ').last;
      expect(_decodePowerShellEncodedCommand(encoded), script);
    });

    test(
      'powershell dialect uses the given shellExecutable for multiline '
      'commands',
      () {
        final prepared = executor.prepareCommand(
          'a\nb',
          dialect: CommandSentinelDialect.powershell,
          shellExecutable: r'C:\pwsh.exe',
        );

        expect(prepared, startsWith(r'C:\pwsh.exe -NoProfile'));
      },
    );

    test('single-line command is unchanged regardless of dialect', () {
      for (final dialect in CommandSentinelDialect.values) {
        expect(
          executor.prepareCommand('git status', dialect: dialect),
          'git status',
        );
      }
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

  group('sentinel fallback dialects', () {
    test('cmd dialect echoes the marker on a separate line via %errorlevel%', () async {
      final terminal = Terminal();
      terminal.write(List.filled(20, '\r\n').join());
      final commands = <String>[];
      final target = CommandExecutionTarget(
        terminal: terminal,
        outputPipe: null,
        sentinelDialect: CommandSentinelDialect.cmd,
        sendCommand: (command) {
          commands.add(command);
          final marker =
              RegExp(r'(__SSTM_\d+__)').firstMatch(command)!.group(1)!;
          terminal.write('\r\n$marker:3\r\n');
        },
        sendRaw: (_) {},
      );
      const executor = TerminalCommandExecutor(
        pollInterval: Duration(milliseconds: 1),
        fallbackTimeout: Duration(milliseconds: 20),
      );

      final result = await executor.execute(target, 'dir');

      final sent = commands.single;
      expect(sent, isNot(contains('__ssterm_ec')));
      expect(sent, isNot(contains(';')));
      // CR, not LF: the classic Windows console line-input mode backing
      // cmd.exe only submits a line on `\r` — see the note in
      // TerminalCommandExecutor.prepareCommand's cmd branch.
      expect(sent, contains('\recho '));
      expect(sent, isNot(contains('\necho ')));
      expect(sent, contains('%errorlevel%'));
      expect(result?.exitCode, 3);
    });

    test(
      'cmd dialect exit code can be negative (NTSTATUS-derived errorlevel)',
      () async {
        final terminal = Terminal();
        terminal.write(List.filled(20, '\r\n').join());
        final target = CommandExecutionTarget(
          terminal: terminal,
          outputPipe: null,
          sentinelDialect: CommandSentinelDialect.cmd,
          sendCommand: (command) {
            final marker =
                RegExp(r'(__SSTM_\d+__)').firstMatch(command)!.group(1)!;
            terminal.write('\r\n$marker:-1073741819\r\n');
          },
          sendRaw: (_) {},
        );
        const executor = TerminalCommandExecutor(
          pollInterval: Duration(milliseconds: 1),
          fallbackTimeout: Duration(milliseconds: 20),
        );

        final result = await executor.execute(target, 'crash.exe');

        expect(result?.exitCode, -1073741819);
      },
    );

    test('powershell dialect uses \$LASTEXITCODE and Console.Out.Write', () async {
      final terminal = Terminal();
      terminal.write(List.filled(20, '\r\n').join());
      final commands = <String>[];
      final target = CommandExecutionTarget(
        terminal: terminal,
        outputPipe: null,
        sentinelDialect: CommandSentinelDialect.powershell,
        sendCommand: (command) {
          commands.add(command);
          final marker =
              RegExp(r'(__SSTM_\d+__)').firstMatch(command)!.group(1)!;
          terminal.write('\r\n$marker:3\r\n');
        },
        sendRaw: (_) {},
      );
      const executor = TerminalCommandExecutor(
        pollInterval: Duration(milliseconds: 1),
        fallbackTimeout: Duration(milliseconds: 20),
      );

      final result = await executor.execute(target, 'Get-Item nope');

      final sent = commands.single;
      expect(sent, contains(r'$LASTEXITCODE'));
      expect(sent, contains('[Console]::Out.Write'));
      expect(sent, isNot(contains('printf')));
      expect(result?.exitCode, 3);
    });
  });
}

/// Decodes a `-EncodedCommand` payload (base64 of UTF-16LE bytes) back to
/// the original script text, mirroring what `powershell.exe` does natively.
/// Used to verify `encodePowerShellCommand` round-trips without needing a
/// real PowerShell process in the test environment.
String _decodePowerShellEncodedCommand(String encoded) {
  final bytes = base64.decode(encoded);
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}
