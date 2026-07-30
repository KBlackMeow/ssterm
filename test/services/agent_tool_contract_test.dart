import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_tool_contract.dart';

void main() {
  group('AgentToolDefinition', () {
    test('serialises a required command parameter as JSON Schema', () {
      const tool = AgentToolDefinition(
        name: 'bash',
        description: 'Run one non-interactive shell command.',
        parameters: {'command': AgentToolParameter.string(required: true)},
      );

      expect(tool.toJsonSchema(), {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
        },
        'required': ['command'],
        'additionalProperties': false,
      });
    });
  });

  group('AgentToolCall', () {
    test('normalises JSON-string arguments into an object', () {
      final call = AgentToolCall.fromRaw(
        id: 'call_1',
        name: 'bash',
        arguments: '{"command":"pwd"}',
      );

      expect(call, isNotNull);
      expect(call!.arguments, {'command': 'pwd'});
    });

    test('rejects malformed or non-object arguments', () {
      expect(
        AgentToolCall.fromRaw(id: 'call_1', name: 'bash', arguments: '{'),
        isNull,
      );
      expect(
        AgentToolCall.fromRaw(id: 'call_1', name: 'bash', arguments: '[]'),
        isNull,
      );
    });

    test('provides a stable legacy transcript representation', () {
      final call = AgentToolCall.fromRaw(
        id: 'call_1',
        name: 'bash',
        arguments: '{"command":"pwd"}',
      )!;

      expect(call.toLegacyJson(), {
        'id': 'call_1',
        'name': 'bash',
        'arguments': {'command': 'pwd'},
      });
    });
  });

  group('AgentConversationItem', () {
    test('keeps a native tool call and its error result correlated by id', () {
      final call = AgentToolCall.fromRaw(
        id: 'call_upload',
        name: 'mcp',
        providerName: 'mcp__matrix__file_upload',
        arguments: {
          'server': 'matrix',
          'tool': 'file_upload',
          'params': {'local_path': '/tmp/book.pdf'},
        },
      )!;
      final result = AgentToolResult(
        toolCallId: call.id,
        content: 'permission denied',
        isError: true,
      );

      final assistant = AgentConversationItem.assistantToolCalls([call]);
      final feedback = AgentConversationItem.toolResults([result]);

      expect(
        assistant.toolCalls.single.providerName,
        'mcp__matrix__file_upload',
      );
      expect(feedback.toolResults.single.toolCallId, 'call_upload');
      expect(feedback.toolResults.single.isError, isTrue);
    });
  });

  group('AgentConversationHistory', () {
    test(
      'turns the next host feedback into native results for pending calls',
      () {
        final call = AgentToolCall.fromRaw(
          id: 'call_write',
          name: 'write_file',
          arguments: const {'path': '/tmp/a.txt', 'content': 'hello'},
        )!;
        final history = AgentConversationHistory()
          ..add(AgentConversationItem.assistantToolCalls([call]))
          ..add({'role': 'user', 'content': '[File write completed]'});

        expect(history, hasLength(2));
        expect(history.last.toolResults.single.toolCallId, 'call_write');
        expect(
          history.last.toolResults.single.content,
          '[File write completed]',
        );
      },
    );

    test(
      'trims native tool calls together with their corresponding results',
      () {
        final call = AgentToolCall.fromRaw(
          id: 'call_1',
          name: 'bash',
          arguments: const {'command': 'pwd'},
        )!;
        final history = AgentConversationHistory()
          ..add(const AgentConversationItem.text(role: 'user', content: 'old'))
          ..add(AgentConversationItem.assistantToolCalls([call]))
          ..add(
            AgentConversationItem.toolResults(const [
              AgentToolResult(toolCallId: 'call_1', content: '/tmp'),
            ]),
          )
          ..add(
            const AgentConversationItem.text(
              role: 'assistant',
              content: 'done',
            ),
          );

        history.trimToMaxItems(maxItems: 2);

        expect(history, hasLength(1));
        expect(history.single.content, 'done');
      },
    );

    test('extends a pinned tool-call head to include its result', () {
      final call = AgentToolCall.fromRaw(
        id: 'call_head',
        name: 'bash',
        arguments: const {'command': 'pwd'},
      )!;
      final history = AgentConversationHistory()
        ..add(const AgentConversationItem.text(role: 'user', content: 'goal'))
        ..add(AgentConversationItem.assistantToolCalls([call]))
        ..add(
          AgentConversationItem.toolResults(const [
            AgentToolResult(toolCallId: 'call_head', content: '/tmp'),
          ]),
        )
        ..add(const AgentConversationItem.text(role: 'assistant', content: 'a'))
        ..add(const AgentConversationItem.text(role: 'user', content: 'b'))
        ..add(
          const AgentConversationItem.text(role: 'assistant', content: 'c'),
        );

      history.trimToMaxItems(maxItems: 4, pinnedItemCount: 2);

      expect(history, hasLength(4));
      expect(history[2].toolResults.single.toolCallId, 'call_head');
      expect(history.last.content, 'c');
    });
  });
}
