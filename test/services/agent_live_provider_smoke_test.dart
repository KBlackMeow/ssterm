import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/models/app_config.dart';
import 'package:ssterm/services/agent_output_store.dart';
import 'package:ssterm/services/agent_read_tools.dart';
import 'package:ssterm/services/agent_stream_client_session.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/file_edit_service.dart';
import 'package:ssterm/services/file_write_service.dart';
import 'package:ssterm/services/llm_service.dart';

void main() {
  Future<AgentConfig> selectedConfig() async {
    final saved = (await AppConfig.load()).agent;
    expect(saved, isNotNull);
    final providerId = Platform.environment['SSTERM_LIVE_PROVIDER'];
    final model = Platform.environment['SSTERM_LIVE_MODEL'];
    final config = providerId == null
        ? saved!
        : saved!.copyWith(defaultProvider: providerId, defaultModel: model);
    expect(config.current?.id, providerId ?? saved.defaultProvider);
    return config;
  }

  test('configured provider returns an answer and token usage', () async {
    final config = await selectedConfig();
    final response = await LlmService.chat(
      config: config,
      messages: [
        AgentConversationItem.text(
          role: 'user',
          content: 'Reply with exactly PING.',
        ),
      ],
      profile: const AgentRequestProfile(
        systemPromptOverride: 'Reply with exactly PING.',
        allowedNativeToolNames: {},
        maxOutputTokens: 128,
      ),
    );
    expect(response.error, isNull);
    expect(response.text.toUpperCase(), contains('PING'));
    expect(response.usage.promptTokenCount, isNotNull);
  }, skip: Platform.environment['SSTERM_LIVE_EVAL'] != '1');

  test(
    'configured provider completes a bounded file-read round trip',
    () async {
      final config = await selectedConfig();
      final root = await Directory.systemTemp.createTemp('ssterm-live-read-');
      try {
        final file = File('${root.path}/marker.txt');
        await file.writeAsString('marker: ORCHID-42\n');
        final history = <AgentConversationItem>[
          AgentConversationItem.text(
            role: 'user',
            content: 'Read ${file.path} using read_file and report its marker.',
          ),
        ];
        const profile = AgentRequestProfile(
          systemPromptOverride:
              'Use read_file to inspect the named file, then answer briefly.',
          allowedNativeToolNames: {'read_file'},
          maxOutputTokens: 512,
        );
        Future<
          ({
            String text,
            String reasoning,
            List<AgentToolCall> calls,
            int? promptTokens,
          })
        >
        request() async {
          final session = AgentStreamClientSession();
          final text = StringBuffer();
          final reasoning = StringBuffer();
          final calls = <AgentToolCall>[];
          int? promptTokens;
          try {
            final request = LlmService.chatStream(
              config: config,
              messages: history,
              session: session,
              profile: profile,
            );
            await for (final event in request.stream) {
              if (event.kind == 'text') text.write(event.content);
              if (event.kind == 'reasoning') reasoning.write(event.content);
              if (event.toolCall != null) calls.add(event.toolCall!);
              promptTokens = event.promptTokenCount ?? promptTokens;
            }
          } finally {
            session.close();
          }
          return (
            text: text.toString(),
            reasoning: reasoning.toString(),
            calls: calls,
            promptTokens: promptTokens,
          );
        }

        final first = await request();
        expect(first.calls, hasLength(1));
        expect(first.calls.single.name, 'read_file');
        history.add(
          AgentConversationItem.assistantToolCalls(
            first.calls,
            content: first.text,
            reasoningContent: first.reasoning,
          ),
        );
        final read = await AgentReadTools(
          outputStore: AgentOutputStore(directory: root, sessionId: 'live'),
          fileSystem: const LocalFileSystemAdapter(),
        ).execute(first.calls.single.name, first.calls.single.arguments);
        expect(read.isError, isFalse);
        history.add(
          AgentConversationItem.toolResults([
            AgentToolResult(
              toolCallId: first.calls.single.id,
              content: read.content,
            ),
          ]),
        );
        final second = await request();
        expect(second.text, contains('ORCHID-42'));
        expect(first.promptTokens, isNotNull);
        expect(second.promptTokens, isNotNull);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['SSTERM_LIVE_EVAL'] != '1',
  );

  test(
    'configured provider completes approved write and edit tool turns',
    () async {
      final config = (await selectedConfig()).copyWith(fileWriteEnabled: true);
      final root = await Directory.systemTemp.createTemp('ssterm-live-write-');
      try {
        final parser = File('${root.path}/parser.dart');
        await parser.writeAsString(
          'int parsePort(String value) => int.parse(value);\n',
        );
        final adapter = LocalFileSystemAdapter(cwdProvider: () => root.path);
        final reads = AgentReadTools(
          outputStore: AgentOutputStore(directory: root, sessionId: 'write'),
          fileSystem: adapter,
        );
        final history = <AgentConversationItem>[
          AgentConversationItem.text(
            role: 'user',
            content:
                'Use edit_file to change ${parser.path} so invalid input returns null while valid ports still parse. Then use write_file to create ${root.path}/result.txt containing exactly COPPER-19 followed by one newline, and ${root.path}/summary.txt containing COPPER-19 and 2 on separate lines.',
          ),
        ];
        const profile = AgentRequestProfile(
          allowedNativeToolNames: {'edit_file', 'write_file', 'read_file'},
          maxOutputTokens: 768,
        );
        var didEdit = false;
        var didWrite = false;
        for (var turn = 0; turn < 8; turn++) {
          final reply = await _streamOnce(config, history, profile);
          if (reply.calls.isEmpty) break;
          history.add(
            AgentConversationItem.assistantToolCalls(
              reply.calls,
              content: reply.text,
              reasoningContent: reply.reasoning,
            ),
          );
          final results = <AgentToolResult>[];
          for (final call in reply.calls) {
            if (call.name == 'write_file') {
              final path = call.arguments['path'] as String;
              final content = call.arguments['content'] as String;
              final result = await adapter.commit(path, content);
              didWrite = true;
              results.add(
                AgentToolResult(
                  toolCallId: call.id,
                  content: FileWriteService.formatSuccessForLlm(result),
                ),
              );
            } else if (call.name == 'edit_file') {
              final path = call.arguments['path'] as String;
              final oldString = call.arguments['old_string'] as String;
              final newString = call.arguments['new_string'] as String;
              final current = await adapter.readContent(path);
              try {
                final edited = FileEditService.applyEdit(
                  current: current,
                  oldString: oldString,
                  newString: newString,
                  replaceAll: call.arguments['replace_all'] == true,
                );
                final result = await adapter.commit(path, edited.newContent);
                didEdit = true;
                results.add(
                  AgentToolResult(
                    toolCallId: call.id,
                    content: FileEditService.formatSuccessForLlm(
                      edited.matchCount,
                      result,
                    ),
                  ),
                );
              } on EditMatchException catch (error) {
                results.add(
                  AgentToolResult(
                    toolCallId: call.id,
                    content: error.kind == EditMatchErrorKind.noMatch
                        ? FileEditService.formatNoMatchForLlm(path, oldString)
                        : FileEditService.formatAmbiguousForLlm(
                            path,
                            oldString,
                            error.matchCount,
                          ),
                    isError: true,
                  ),
                );
              }
            } else if (call.name == 'read_file') {
              final read = await reads.execute(call.name, call.arguments);
              results.add(
                AgentToolResult(
                  toolCallId: call.id,
                  content: read.content,
                  isError: read.isError,
                ),
              );
            } else {
              results.add(
                AgentToolResult(
                  toolCallId: call.id,
                  content:
                      '[Tool call was not executed] ${call.name} is unavailable. Use edit_file or write_file only.',
                  isError: true,
                ),
              );
            }
          }
          history.add(AgentConversationItem.toolResults(results));
        }
        expect(didEdit, isTrue);
        expect(didWrite, isTrue);
        expect(await parser.readAsString(), contains('tryParse'));
        expect(
          await File('${root.path}/result.txt').readAsString(),
          'COPPER-19\n',
        );
        expect(
          await File('${root.path}/summary.txt').readAsString(),
          allOf(contains('COPPER-19'), contains('2')),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['SSTERM_LIVE_EVAL'] != '1',
  );
}

Future<({String text, String reasoning, List<AgentToolCall> calls})>
_streamOnce(
  AgentConfig config,
  List<AgentConversationItem> history,
  AgentRequestProfile profile,
) async {
  final session = AgentStreamClientSession();
  final text = StringBuffer();
  final reasoning = StringBuffer();
  final calls = <AgentToolCall>[];
  try {
    final request = LlmService.chatStream(
      config: config,
      messages: history,
      session: session,
      profile: profile,
    );
    await for (final event in request.stream) {
      if (event.kind == 'text') text.write(event.content);
      if (event.kind == 'reasoning') reasoning.write(event.content);
      if (event.toolCall != null) calls.add(event.toolCall!);
    }
  } finally {
    session.close();
  }
  return (text: text.toString(), reasoning: reasoning.toString(), calls: calls);
}
