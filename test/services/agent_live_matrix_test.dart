import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/models/app_config.dart';
import 'package:ssterm/services/agent_output_store.dart';
import 'package:ssterm/services/agent_read_tools.dart';
import 'package:ssterm/services/agent_stream_client_session.dart';
import 'package:ssterm/services/agent_tool_batch.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';
import 'package:ssterm/services/command_feedback_formatter.dart';
import 'package:ssterm/services/file_write_service.dart';
import 'package:ssterm/services/llm_service.dart';

/// Runs fixed read-only Agent tasks against the configured real model.
/// This headless driver compares the old/new tool catalogue and feedback cap.
/// It does not test the panel's approval UI or remote execution.
void main() {
  test(
    'read-only fixture classifier accepts quoted pipes and context tools',
    () {
      expect(
        _readOnlyCommand(
          'grep -n -i -E "error|FAILED" logs/build.log | head -50',
        ),
        isTrue,
      );
      expect(_readOnlyCommand("sed -n '6995,7010p' logs/build.log"), isTrue);
      expect(
        _readOnlyCommand('ls -la; wc -l logs/build.log 2>/dev/null'),
        isTrue,
      );
      expect(
        _readOnlyCommand(
          r'''awk 'NR>=6995 && NR<=7008 {print NR": "$0}' logs/build.log''',
        ),
        isTrue,
      );
      expect(_readOnlyCommand('grep marker x | rm x'), isFalse);
      expect(_readOnlyCommand("sed -i 's/a/b/' x"), isFalse);
      expect(_readOnlyCommand("sed -n '1w /tmp/out' x"), isFalse);
      expect(_readOnlyCommand("awk '{print > \"/tmp/out\"}' x"), isFalse);
    },
  );

  test(
    'live local read matrix',
    () async {
      final saved = (await AppConfig.load()).agent!;
      final provider = Platform.environment['SSTERM_LIVE_PROVIDER'];
      final model = Platform.environment['SSTERM_LIVE_MODEL'];
      final config = saved.copyWith(
        defaultProvider: provider,
        defaultModel: model,
        webSearchEnabled: false,
        fileWriteEnabled: false,
        mcpEnabled: false,
        enabledSkills: {},
      );
      expect(config.current?.id, provider ?? saved.defaultProvider);
      final selected = Platform.environment['SSTERM_LIVE_CASES']
          ?.split(',')
          .toSet();
      final repetitions =
          int.tryParse(Platform.environment['SSTERM_LIVE_REPS'] ?? '') ?? 3;
      final maxTurns =
          int.tryParse(Platform.environment['SSTERM_LIVE_MAX_TURNS'] ?? '') ??
          16;
      final report = File(
        Platform.environment['SSTERM_LIVE_REPORT'] ??
            '${Directory.systemTemp.path}/ssterm-agent-live-matrix.csv',
      );
      await report.writeAsString(
        'variant,case,repetition,passed,prompt_tokens,tool_calls,tool_errors,turns,answer\n',
      );
      for (final variant in ['baseline', 'current']) {
        final selectedVariant = Platform.environment['SSTERM_LIVE_VARIANT'];
        if (selectedVariant != null && selectedVariant != variant) continue;
        for (final task in _tasks) {
          if (selected != null && !selected.contains(task.id)) continue;
          for (var rep = 1; rep <= repetitions; rep++) {
            final root = await _fixture();
            try {
              final result = await _run(
                config: config,
                variant: variant,
                task: task,
                root: root,
                maxTurns: maxTurns,
              );
              final passed = task.passes(result.answer, root.path);
              final answer = result.answer
                  .replaceAll(RegExp(r'[\r\n,]+'), ' ')
                  .replaceAll('"', "'");
              final line =
                  '$variant,${task.id},$rep,$passed,'
                  '${result.promptTokens},${result.toolCalls},'
                  '${result.toolErrors},${result.turns},"$answer"\n';
              await report.writeAsString(line, mode: FileMode.append);
              stdout.write(line);
            } finally {
              await root.delete(recursive: true);
            }
          }
        }
      }
      stdout.writeln('report=${report.path}');
    },
    skip: Platform.environment['SSTERM_LIVE_MATRIX'] != '1',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

typedef _Task = ({
  String id,
  String prompt,
  bool Function(String answer, String root) passes,
});

final _tasks = <_Task>[
  (
    id: '01',
    prompt: 'What is the current working directory?',
    passes: (a, r) => a.contains(r),
  ),
  (
    id: '02',
    prompt: 'Find answer.txt and give its release code.',
    passes: (a, _) => a.contains('COPPER-19'),
  ),
  (
    id: '03',
    prompt: 'What is the final marker in notes/alpha.txt?',
    passes: (a, _) => a.contains('ORCHID-42'),
  ),
  (
    id: '04',
    prompt: 'How many lines are in notes/alpha.txt?',
    passes: (a, _) => RegExp(r'\b4\b').hasMatch(a),
  ),
  (
    id: '05',
    prompt: 'Give the last line of notes/unicode.txt.',
    passes: (a, _) => a.contains('最后一行：蓝色'),
  ),
  (
    id: '06',
    prompt: 'Count case-insensitive matches for moon in notes/case.txt.',
    passes: (a, _) => RegExp(r'\b3\b').hasMatch(a),
  ),
  (
    id: '07',
    prompt: 'What is limit in data/settings.json?',
    passes: (a, _) => RegExp(r'\b7\b').hasMatch(a),
  ),
  (
    id: '08',
    prompt: 'Which record has status failed in data/records.csv?',
    passes: (a, _) => RegExp(r'\b2\b').hasMatch(a),
  ),
  (
    id: '09',
    prompt: 'Find the function that parses a port in this fixture.',
    passes: (a, _) => a.contains('parsePort') && a.contains('parser.dart'),
  ),
  (
    id: '12',
    prompt: 'Read the marker at the end of large/huge.txt.',
    passes: (a, _) => a.contains('HORIZON-88'),
  ),
  (
    id: '13',
    prompt: 'Find the error marker in logs/build.log.',
    passes: (a, _) => a.contains('NEBULA-73'),
  ),
  (
    id: '14',
    prompt: 'Show the line around the error in logs/build.log.',
    passes: (a, _) => a.contains('ERROR: missing config marker'),
  ),
  (
    id: '15',
    prompt:
        'Run a command that checks whether notes/missing.txt exists, then tell me the outcome.',
    passes: (a, _) => RegExp(
      r'absent|missing|does not exist|not found|不存在',
      caseSensitive: false,
    ).hasMatch(a),
  ),
  (
    id: '16',
    prompt: 'Is empty.txt empty? Verify from the file.',
    passes: (a, _) => RegExp(
      r'empty|0 bytes|0 lines|空文件|是空',
      caseSensitive: false,
    ).hasMatch(a),
  ),
  (
    id: '17',
    prompt: 'Check the release code and error marker, then report both.',
    passes: (a, _) => a.contains('COPPER-19') && a.contains('NEBULA-73'),
  ),
];

Future<Directory> _fixture() async {
  final root = await Directory.systemTemp.createTemp('ssterm-matrix-');
  Future<void> write(String relative, String content) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  await write(
    'notes/alpha.txt',
    'alpha\nbeta\ngamma\nfinal-marker: ORCHID-42\n',
  );
  await write('notes/unicode.txt', '第一行\nemoji: 🐈\n最后一行：蓝色\n');
  await write('notes/case.txt', 'Moon\nmoon\nMOON\nsun\n');
  await write('data/settings.json', '{"mode":"safe","limit":7}\n');
  await write('data/records.csv', 'id,status\n1,ok\n2,failed\n3,ok\n');
  await write(
    'src/parser.dart',
    'int parsePort(String value) => int.parse(value);\n',
  );
  await write('src/answer.txt', 'The release code is COPPER-19.\n');
  await write(
    'logs/build.log',
    '${'INFO background activity\n' * 7000}ERROR: missing config marker: NEBULA-73\n${'INFO recovery activity\n' * 7000}',
  );
  await write(
    'large/huge.txt',
    '${'ordinary line\n' * 400000}tail marker: HORIZON-88\n',
  );
  await write('empty.txt', '');
  return root;
}

typedef _RunResult = ({
  String answer,
  int promptTokens,
  int toolCalls,
  int toolErrors,
  int turns,
});

Future<_RunResult> _run({
  required AgentConfig config,
  required String variant,
  required _Task task,
  required Directory root,
  required int maxTurns,
}) async {
  final old = variant == 'baseline';
  final history = <AgentConversationItem>[
    AgentConversationItem.text(
      role: 'user',
      content:
          '<session_context>\nactive_tab: local\ncwd: ${root.path}\n</session_context>\n\n${task.prompt}',
    ),
  ];
  final store = AgentOutputStore(
    directory: Directory('${root.path}/.artifacts'),
    sessionId: 'live',
    maxArtifactBytes: old ? 64 * 1024 : 256 * 1024,
    maxSessionBytes: old ? 512 * 1024 : 2 * 1024 * 1024,
  );
  final reads = AgentReadTools(
    outputStore: store,
    fileSystem: LocalFileSystemAdapter(cwdProvider: () => root.path),
  );
  final formatter = old
      ? const CommandFeedbackFormatter(
          maxFeedbackBytes: 8 * 1024,
          headBytes: 4 * 1024,
          tailBytes: 4 * 1024,
        )
      : const CommandFeedbackFormatter();
  const oldNames = {'bash', 'ask_user_question', 'read_image'};
  final profile = old
      ? const AgentRequestProfile(allowedNativeToolNames: oldNames)
      : null;
  final registry = AgentToolRegistry.build();
  var session = AgentStreamClientSession();
  var promptTokens = 0;
  var toolCalls = 0;
  var toolErrors = 0;
  var turns = 0;
  var answer = '';
  try {
    for (turns = 1; turns <= maxTurns; turns++) {
      var text = StringBuffer();
      var reasoning = StringBuffer();
      var calls = <AgentToolCall>[];
      for (var attempt = 0; attempt < 3; attempt++) {
        var hadOutput = false;
        try {
          final request = LlmService.chatStream(
            config: config,
            messages: history,
            session: session,
            profile: profile,
          );
          await for (final event in request.stream.timeout(
            const Duration(seconds: 60),
          )) {
            if (event.kind == 'text') {
              text.write(event.content);
              hadOutput = hadOutput || event.content.isNotEmpty;
            }
            if (event.kind == 'reasoning') {
              reasoning.write(event.content);
              hadOutput = hadOutput || event.content.isNotEmpty;
            }
            if (event.toolCall != null) {
              calls.add(event.toolCall!);
              hadOutput = true;
            }
            if (event.promptTokenCount != null) {
              promptTokens += event.promptTokenCount!;
            }
          }
          break;
        } catch (error) {
          if (hadOutput || attempt == 2 || !_transient(error)) rethrow;
          session.close(force: true);
          session = AgentStreamClientSession();
          text = StringBuffer();
          reasoning = StringBuffer();
          calls = <AgentToolCall>[];
          await Future<void>.delayed(
            Duration(milliseconds: 250 * (attempt + 1)),
          );
        }
      }
      if (calls.isEmpty) {
        answer = LlmService.stripCompletionMarkers(text.toString());
        break;
      }
      toolCalls += calls.length;
      history.add(
        AgentConversationItem.assistantToolCalls(
          calls,
          content: text.isEmpty ? null : text.toString(),
          reasoningContent: reasoning.toString(),
        ),
      );
      final rejection = old
          ? null
          : AgentToolBatch.rejectionReason(calls, registry);
      final results = <AgentToolResult>[];
      for (final call in calls) {
        if (Platform.environment['SSTERM_LIVE_TRACE'] == '1') {
          stdout.writeln(
            'trace $variant ${task.id} turn=$turns '
            '${call.name} ${jsonEncode(call.arguments)}',
          );
        }
        String content;
        var isError = false;
        if (rejection != null) {
          content = '[Tool call was not executed] $rejection';
          isError = true;
        } else if (call.name == 'bash') {
          final command = call.arguments['command']?.toString() ?? '';
          if (!_readOnlyCommand(command)) {
            content = '[Command rejected] Read-only fixture commands only.';
            isError = true;
          } else {
            try {
              final process = await Process.run(
                'zsh',
                ['-lc', command],
                workingDirectory: root.path,
                environment: {'HOME': root.path},
              ).timeout(const Duration(seconds: 10));
              final output = '${process.stdout}${process.stderr}';
              final commandResult = CommandResult(
                output: output,
                exitCode: process.exitCode,
              );
              final artifact = output.isEmpty ? null : await store.save(output);
              content = formatter.format(
                command,
                commandResult,
                toolCallId: call.id,
                artifact: artifact,
              );
              isError = process.exitCode != 0;
            } catch (error) {
              content = '[Command failed] $error';
              isError = true;
            }
          }
        } else if (!old &&
            const {
              'read_file',
              'grep_file',
              'read_output',
            }.contains(call.name)) {
          final read = await reads.execute(call.name, call.arguments);
          content = read.content;
          isError = read.isError;
        } else {
          content = '[Tool unavailable in this read-only evaluation]';
          isError = true;
        }
        if (isError) toolErrors++;
        if (Platform.environment['SSTERM_LIVE_TRACE'] == '1') {
          stdout.writeln(
            'trace result error=$isError '
            '${content.replaceAll('\n', ' ').substring(0, content.length < 300 ? content.length : 300)}',
          );
        }
        results.add(
          AgentToolResult(
            toolCallId: call.id,
            content: content,
            isError: isError,
          ),
        );
      }
      history.add(AgentConversationItem.toolResults(results));
    }
  } catch (error) {
    answer = '[Evaluation error] $error';
  } finally {
    session.close();
  }
  return (
    answer: answer,
    promptTokens: promptTokens,
    toolCalls: toolCalls,
    toolErrors: toolErrors,
    turns: turns.clamp(0, maxTurns),
  );
}

bool _transient(Object error) =>
    error is TimeoutException ||
    error is SocketException ||
    error is HandshakeException ||
    error is HttpException;

bool _readOnlyCommand(String command) {
  final normalized = command
      .replaceAll('2>&1', '')
      .replaceAll('2>/dev/null', '');
  if (normalized.isEmpty ||
      RegExp(
        r'[`\n]|\$\(|(?:^|\s)-(?:exec|execdir|delete|ok)\b',
      ).hasMatch(normalized) ||
      RegExp(r'\bsed\s+-[^\s]*i').hasMatch(normalized) ||
      RegExp(r'\bawk\b[\s\S]*\bsystem\s*\(').hasMatch(normalized)) {
    return false;
  }
  const allowed = {
    'pwd',
    'cd',
    'find',
    'cat',
    'tail',
    'head',
    'wc',
    'grep',
    'rg',
    'sed',
    'awk',
    'ls',
    'test',
    'stat',
    'sort',
    'uniq',
    'file',
    'echo',
    'printf',
    'cut',
    'tr',
  };
  final parts = _splitReadOnlyCommands(normalized);
  if (parts == null) return false;
  return parts.every((part) {
    final words = part.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || !allowed.contains(words.first)) return false;
    if (words.first == 'sed') {
      return RegExp(
        r'''^sed\s+-n\s+['"]?\d+(?:,\d+)?p['"]?\s+\S+$''',
      ).hasMatch(part);
    }
    if (words.first == 'awk') {
      return RegExp(
        r'''^awk\s+'NR>=\d+\s+&&\s+NR<=\d+\s+\{print\s+NR": "\$0\}'\s+\S+$''',
      ).hasMatch(part);
    }
    return true;
  });
}

/// Splits shell operators only when they are outside quotes. This is a
/// diagnostic whitelist, not the product's command parser.
List<String>? _splitReadOnlyCommands(String command) {
  final parts = <String>[];
  var current = StringBuffer();
  String? quote;
  var escaped = false;
  for (var index = 0; index < command.length; index++) {
    final char = command[index];
    if (escaped) {
      current.write(char);
      escaped = false;
      continue;
    }
    if (char == r'\' && quote != "'") {
      current.write(char);
      escaped = true;
      continue;
    }
    if (quote != null) {
      current.write(char);
      if (char == quote) quote = null;
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      current.write(char);
      continue;
    }
    if (char == '>' || char == '<') return null;
    if (char == ';' || char == '|' || char == '&') {
      if (char == '&' &&
          (index + 1 >= command.length || command[index + 1] != '&')) {
        return null;
      }
      final part = current.toString().trim();
      if (part.isEmpty) return null;
      parts.add(part);
      current = StringBuffer();
      if ((char == '|' || char == '&') &&
          index + 1 < command.length &&
          command[index + 1] == char) {
        index++;
      }
      continue;
    }
    current.write(char);
  }
  if (quote != null || escaped) return null;
  final tail = current.toString().trim();
  if (tail.isEmpty) return null;
  parts.add(tail);
  return parts;
}
