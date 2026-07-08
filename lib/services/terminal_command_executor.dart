import 'dart:typed_data';

import 'package:xterm/xterm.dart';

import '../io/output_pipe.dart';
import 'command_safety.dart';
import 'shell_integration.dart';

class CommandExecutionTarget {
  const CommandExecutionTarget({
    required this.terminal,
    required this.outputPipe,
    required this.sendCommand,
    required this.sendRaw,
  });

  final Terminal terminal;
  final OutputPipe? outputPipe;
  final void Function(String command) sendCommand;
  final void Function(Uint8List bytes) sendRaw;
}

class TerminalCommandExecutor {
  const TerminalCommandExecutor({
    this.oscTimeout = const Duration(seconds: 120),
    this.recoveryTimeout = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 200),
    this.fallbackTimeout = const Duration(seconds: 120),
    this.log,
  });

  final Duration oscTimeout;
  final Duration recoveryTimeout;
  final Duration pollInterval;
  final Duration fallbackTimeout;
  final void Function(String message)? log;

  String prepareCommand(String command) {
    if (!command.contains('\n')) return command;

    final escaped = command.replaceAll("'", "'\\''");
    return r"${SSTM_SHELL_BIN:-sh} -c '"
        "$escaped'";
  }

  Future<CommandResult?> execute(
    CommandExecutionTarget target,
    String command, {
    bool Function()? isCancelled,
  }) async {
    final terminal = target.terminal;
    if (terminal.isUsingAltBuffer) {
      _log('[capture] blocked cmd=${_quote(command)} reason=alt_screen');
      return CommandResult(
        output: '[ssterm safety check] ${CommandSafety.altScreenReason}',
        exitCode: null,
      );
    }

    final safetyReason = CommandSafety.reason(command);
    if (safetyReason != null) {
      _log(
        '[capture] blocked cmd=${_quote(command)} '
        'reason=${_quote(safetyReason)}',
      );
      return CommandResult(
        output: '[ssterm safety check] $safetyReason',
        exitCode: null,
      );
    }

    final prepared = prepareCommand(command);
    final pipe = target.outputPipe;
    if (pipe != null && pipe.hasOsc133) {
      return _executeOsc133(target, command, prepared, pipe, isCancelled);
    }
    return _executeWithSentinel(target, command, prepared, isCancelled);
  }

  Future<CommandResult?> _executeOsc133(
    CommandExecutionTarget target,
    String command,
    String prepared,
    OutputPipe pipe,
    bool Function()? isCancelled,
  ) async {
    final pending = pipe.awaitNextCommand(
      timeout: oscTimeout,
      isCancelled: isCancelled,
    );
    target.sendCommand(prepared);
    final result = await pending;
    if (result != null) {
      _log(
        '[capture] osc133 done cmd=${_quote(command)} '
        'exit=${result.exitCode} bytes=${result.output.length}',
      );
      return result;
    }
    if (isCancelled?.call() == true) {
      _log('[capture] osc133 cancelled');
      return null;
    }

    _log(
      '[capture] osc133 timeout after ${oscTimeout.inSeconds}s '
      '— sending Ctrl-C to abort stuck command',
    );
    target.sendRaw(Uint8List.fromList(const [0x03]));
    final recovery = await pipe.awaitNextCommand(
      timeout: recoveryTimeout,
      isCancelled: isCancelled,
    );
    if (recovery != null) {
      _log(
        '[capture] osc133 recovered after Ctrl-C '
        'exit=${recovery.exitCode}',
      );
      return recovery;
    }
    if (isCancelled?.call() == true) {
      _log('[capture] osc133 abort cancelled');
      return null;
    }
    _log(
      '[capture] osc133 unrecoverable timeout — giving up; '
      'shell may still be busy',
    );
    return CommandResult(
      output:
          '[ssterm capture] command exceeded '
          '${oscTimeout.inSeconds}s without producing its OSC 133 ;D '
          'marker; Ctrl-C was sent but the shell did not return to a '
          'prompt. The command may still be running — please switch to '
          'the terminal and clean up before continuing.',
      exitCode: null,
    );
  }

  Future<CommandResult?> _executeWithSentinel(
    CommandExecutionTarget target,
    String command,
    String prepared,
    bool Function()? isCancelled,
  ) async {
    final terminal = target.terminal;
    final beforeLen = terminal.buffer.lines.length;
    final marker = '__SSTM_${DateTime.now().microsecondsSinceEpoch}__';
    target.sendCommand(
      '$prepared; __ssterm_ec=\$?; '
      'printf "$marker:%s\\n" "\$__ssterm_ec"',
    );

    final stopwatch = Stopwatch()..start();
    var pollCount = 0;

    int? extractExit() {
      final lines = terminal.buffer.lines;
      for (var i = lines.length - 1; i >= 0 && i >= lines.length - 8; i--) {
        final text = lines[i].toString();
        final index = text.indexOf('$marker:');
        if (index < 0) continue;
        final tail = text.substring(index + marker.length + 1);
        final match = RegExp(r'^(\d+)').firstMatch(tail);
        return match == null ? 0 : int.tryParse(match.group(1)!);
      }
      return null;
    }

    int? exitCode;
    while (stopwatch.elapsed < fallbackTimeout) {
      if (isCancelled?.call() == true) {
        _log('[capture] echo cancelled poll=$pollCount');
        return null;
      }
      await Future<void>.delayed(pollInterval);
      pollCount++;
      exitCode = extractExit();
      if (exitCode != null) break;
    }

    var timedOut = false;
    if (exitCode == null) {
      timedOut = true;
      _log(
        '[capture] echo timeout after ${stopwatch.elapsedMilliseconds}ms '
        '— sending Ctrl-C to abort stuck command',
      );
      target.sendRaw(Uint8List.fromList(const [0x03]));
      final abortStart = Stopwatch()..start();
      while (abortStart.elapsed < recoveryTimeout) {
        if (isCancelled?.call() == true) {
          _log('[capture] echo abort cancelled');
          return null;
        }
        await Future<void>.delayed(pollInterval);
        pollCount++;
        exitCode = extractExit();
        if (exitCode != null) {
          _log('[capture] echo recovered after Ctrl-C exit=$exitCode');
          break;
        }
      }
      if (exitCode == null) {
        _log(
          '[capture] echo unrecoverable timeout — giving up; '
          'shell may still be busy',
        );
        return CommandResult(
          output:
              '[ssterm capture] command exceeded '
              '${fallbackTimeout.inSeconds}s without producing its sentinel; '
              'Ctrl-C was sent but the shell did not return to a prompt. '
              'The command may still be running — please switch to the '
              'terminal and clean up before continuing.',
          exitCode: null,
        );
      }
    }

    final len = terminal.buffer.lines.length;
    final totalLines = len - beforeLen;
    final cap = beforeLen + 2000;
    final start = len > cap ? len - 2000 : beforeLen;
    final actualStart = start < len ? start : (len > 2000 ? len - 2000 : 0);
    final lines = <String>[];
    for (var i = actualStart; i < len; i++) {
      final line = terminal.buffer.lines[i].toString();
      if (line.contains(marker) || line.contains('__ssterm_ec=')) continue;
      lines.add(line);
    }
    final cleaned = stripAnsi(lines.join('\n')).trim();
    final wasTruncated = totalLines > 2000;
    _log(
      '[capture] echo done cmd=${_quote(command)} '
      'exit=$exitCode bytes=${cleaned.length} '
      'lines=${lines.length} polls=$pollCount '
      'elapsed=${stopwatch.elapsedMilliseconds}ms truncated=$wasTruncated '
      'timedOut=$timedOut',
    );
    return CommandResult(
      output: cleaned,
      exitCode: exitCode,
      truncated: wasTruncated,
    );
  }

  void _log(String message) => log?.call(message);

  static String _quote(String value) {
    const cap = 120;
    var escaped = value
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    if (escaped.length > cap) escaped = '${escaped.substring(0, cap)}…';
    return '"$escaped"';
  }
}
