import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_provider_tools.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';
import 'package:ssterm/models/mcp_server_config.dart';
import 'package:ssterm/services/agent_image_attachment.dart';

void main() {
  final registry = AgentToolRegistry.build(
    webSearchEnabled: true,
    fileWriteEnabled: true,
  );

  test('encodes OpenAI-compatible function tools', () {
    final tools = AgentProviderTools.openAiTools(registry.definitions);

    expect(tools.first['type'], 'function');
    final function = tools.first['function'] as Map;
    expect(function['name'], 'bash');
    expect(function['description'], contains('shell'));
    expect(function['parameters'], isA<Map<String, Object>>());
    expect(function['strict'], isTrue);
  });

  test('encodes Anthropic input schemas', () {
    final tools = AgentProviderTools.anthropicTools(registry.definitions);

    expect(tools.first['name'], 'bash');
    expect(tools.first['input_schema'], isA<Map<String, Object>>());
  });

  test('encodes Gemini function declarations', () {
    final tools = AgentProviderTools.geminiTools(registry.definitions);

    final declarations = tools.single['functionDeclarations'] as List;
    expect((declarations.first as Map)['name'], 'bash');
  });

  test('removes unsupported additionalProperties recursively for Gemini', () {
    final tools = AgentProviderTools.geminiTools(registry.definitions);
    final declarations = tools.single['functionDeclarations'] as List;

    bool containsAdditionalProperties(Object? value) {
      if (value is Map) {
        return value.containsKey('additionalProperties') ||
            value.values.any(containsAdditionalProperties);
      }
      if (value is Iterable) return value.any(containsAdditionalProperties);
      return false;
    }

    expect(containsAdditionalProperties(declarations), isFalse);
  });

  test('serializes user image attachments for every multimodal provider', () {
    const image = AgentImageAttachment(
      mimeType: 'image/png',
      base64Data: 'aGVsbG8=',
      displayName: 'diagram.png',
    );
    final transcript = [
      const AgentConversationItem.text(
        role: 'user',
        content: 'What is shown?',
        images: [image],
      ),
    ];

    expect(AgentProviderTools.openAiMessages(transcript).single, {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'What is shown?'},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
        },
      ],
    });
    expect(AgentProviderTools.anthropicMessages(transcript).single, {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'What is shown?'},
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/png',
            'data': 'aGVsbG8=',
          },
        },
      ],
    });
    expect(AgentProviderTools.geminiContents(transcript).single, {
      'role': 'user',
      'parts': [
        {'text': 'What is shown?'},
        {
          'inlineData': {'mimeType': 'image/png', 'data': 'aGVsbG8='},
        },
      ],
    });
  });

  test('serializes image-returning tool results as vision input', () {
    const image = AgentImageAttachment(
      mimeType: 'image/png',
      base64Data: 'aGVsbG8=',
      displayName: 'diagram.png',
    );
    final transcript = [
      AgentConversationItem.toolResults(const [
        AgentToolResult(
          toolCallId: 'call_image',
          content: 'Loaded image: diagram.png',
          images: [image],
        ),
      ]),
    ];

    final openAi = AgentProviderTools.openAiMessages(transcript);
    expect(openAi, hasLength(2));
    expect((openAi[1]['content'] as List).last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
    });
    final anthropic = AgentProviderTools.anthropicMessages(transcript);
    expect(
      ((anthropic.single['content'] as List).single['content'] as List).last,
      containsPair('type', 'image'),
    );
    final gemini = AgentProviderTools.geminiContents(transcript);
    expect((gemini.single['parts'] as List).last, {
      'inlineData': {'mimeType': 'image/png', 'data': 'aGVsbG8='},
    });
  });

  test('serializes image attachments for Ollama native chat', () {
    const image = AgentImageAttachment(
      mimeType: 'image/png',
      base64Data: 'aGVsbG8=',
      displayName: 'diagram.png',
    );

    final messages = AgentProviderTools.ollamaMessages([
      const AgentConversationItem.text(
        role: 'user',
        content: 'What is shown?',
        images: [image],
      ),
    ]);

    expect(messages.single, {
      'role': 'user',
      'content': 'What is shown?',
      'images': ['aGVsbG8='],
    });
  });

  test('encodes each MCP tool for OpenAI, Claude, and Gemini', () {
    final mcpRegistry = AgentToolRegistry.build(
      mcpTools: const [
        McpTool(
          serverId: 'matrix',
          serverName: 'Matrix',
          name: 'send_message',
          description: 'Send a Matrix message',
          inputSchema: {
            'type': 'object',
            'properties': {
              'room_id': {'type': 'string'},
              'text': {'type': 'string'},
            },
            'required': ['room_id', 'text'],
          },
        ),
      ],
    );

    final openAiTools = AgentProviderTools.openAiTools(mcpRegistry.definitions);
    final openAiFunction = openAiTools
        .map((tool) => tool['function'] as Map)
        .singleWhere((item) => item['name'] == 'mcp__matrix__send_message');

    const expectedSchema = {
      'type': 'object',
      'properties': {
        'room_id': {'type': 'string'},
        'text': {'type': 'string'},
      },
      'required': ['room_id', 'text'],
    };
    expect(openAiFunction['description'], 'Send a Matrix message');
    expect(openAiFunction['parameters'], expectedSchema);
    expect(openAiFunction['strict'], isFalse);

    final anthropicFunction = AgentProviderTools.anthropicTools(
      mcpRegistry.definitions,
    ).singleWhere((item) => item['name'] == 'mcp__matrix__send_message');
    expect(anthropicFunction['input_schema'], expectedSchema);

    final geminiDeclarations =
        AgentProviderTools.geminiTools(
              mcpRegistry.definitions,
            ).single['functionDeclarations']
            as List;
    final geminiFunction = geminiDeclarations.cast<Map>().singleWhere(
      (item) => item['name'] == 'mcp__matrix__send_message',
    );
    expect(geminiFunction['parameters'], expectedSchema);
  });

  test('serializes a native call and result in all provider formats', () {
    final call = AgentToolCall.fromRaw(
      id: 'call_upload',
      name: 'mcp',
      providerName: 'mcp__matrix__file_upload',
      providerArguments: const {'local_path': '/tmp/book.pdf'},
      arguments: const {
        'server': 'matrix',
        'tool': 'file_upload',
        'params': {'local_path': '/tmp/book.pdf'},
      },
    )!;
    final transcript = [
      const AgentConversationItem.text(role: 'user', content: 'Upload it'),
      AgentConversationItem.assistantToolCalls([call]),
      AgentConversationItem.toolResults(const [
        AgentToolResult(
          toolCallId: 'call_upload',
          content: 'permission denied',
          isError: true,
        ),
      ]),
    ];

    final openAi = AgentProviderTools.openAiMessages(transcript);
    expect((openAi[1]['tool_calls'] as List).single, {
      'id': 'call_upload',
      'type': 'function',
      'function': {
        'name': 'mcp__matrix__file_upload',
        'arguments': '{"local_path":"/tmp/book.pdf"}',
      },
    });
    expect(openAi[2], {
      'role': 'tool',
      'tool_call_id': 'call_upload',
      'content': 'permission denied',
    });

    final anthropic = AgentProviderTools.anthropicMessages(transcript);
    expect((anthropic[1]['content'] as List).single, {
      'type': 'tool_use',
      'id': 'call_upload',
      'name': 'mcp__matrix__file_upload',
      'input': {'local_path': '/tmp/book.pdf'},
    });
    expect((anthropic[2]['content'] as List).single, {
      'type': 'tool_result',
      'tool_use_id': 'call_upload',
      'content': 'permission denied',
      'is_error': true,
    });

    final gemini = AgentProviderTools.geminiContents(transcript);
    expect((gemini[1]['parts'] as List).single, {
      'functionCall': {
        'name': 'mcp__matrix__file_upload',
        'args': {'local_path': '/tmp/book.pdf'},
      },
    });
    expect((gemini[2]['parts'] as List).single, {
      'functionResponse': {
        'name': 'mcp__matrix__file_upload',
        'response': {
          'tool_call_id': 'call_upload',
          'content': 'permission denied',
          'is_error': true,
        },
      },
    });
  });

  test(
    'preserves Gemini function-call thought signatures across tool results',
    () {
      final call = AgentToolCall.fromRaw(
        id: 'call_gemini_1',
        name: 'bash',
        arguments: const {'command': 'pwd'},
        thoughtSignature: 'encrypted-signature',
      )!;
      final contents = AgentProviderTools.geminiContents([
        AgentConversationItem.assistantToolCalls([call]),
        AgentConversationItem.toolResults(const [
          AgentToolResult(toolCallId: 'call_gemini_1', content: '/workspace'),
        ]),
      ]);

      expect((contents[0]['parts'] as List).single, {
        'functionCall': {
          'name': 'bash',
          'args': {'command': 'pwd'},
        },
        'thoughtSignature': 'encrypted-signature',
      });
      expect((contents[1]['parts'] as List).single, {
        'functionResponse': {
          'name': 'bash',
          'response': {
            'tool_call_id': 'call_gemini_1',
            'content': '/workspace',
          },
        },
      });
    },
  );

  test('replays DeepSeek reasoning content with an assistant tool call', () {
    final call = AgentToolCall.fromRaw(
      id: 'call_deepseek_1',
      name: 'bash',
      arguments: const {'command': 'pwd'},
    )!;

    final messages = AgentProviderTools.openAiMessages([
      AgentConversationItem.assistantToolCalls([
        call,
      ], reasoningContent: 'Need inspect the current working directory first.'),
    ], includeReasoningContent: true);

    expect(
      messages.single['reasoning_content'],
      'Need inspect the current working directory first.',
    );
  });

  test('replays Anthropic thinking blocks with assistant tool calls', () {
    final call = AgentToolCall.fromRaw(
      id: 'call_minimax_1',
      name: 'bash',
      arguments: const {'command': 'pwd'},
    )!;
    final messages = AgentProviderTools.anthropicMessages([
      AgentConversationItem.assistantToolCalls(
        [call],
        thinkingBlocks: const [
          AgentThinkingBlock(
            thinking: 'I need the working directory before continuing.',
            signature: 'provider-signature',
          ),
        ],
      ),
    ]);

    expect(messages.single['content'], [
      {
        'type': 'thinking',
        'thinking': 'I need the working directory before continuing.',
        'signature': 'provider-signature',
      },
      {
        'type': 'tool_use',
        'id': 'call_minimax_1',
        'name': 'bash',
        'input': {'command': 'pwd'},
      },
    ]);
  });

  test('backfilled interrupted tool result serializes a valid transcript', () {
    // Mirrors `_completeInterruptedToolCalls`: an interrupted turn leaves a
    // dangling assistant tool call; backfilling an isError tool result keeps
    // the next provider request valid (tool_use → tool_result for Anthropic,
    // assistant tool_calls → role:tool for OpenAI).
    final call = AgentToolCall.fromRaw(
      id: 'call_stop',
      name: 'bash',
      arguments: const {'command': 'sleep 60'},
    )!;
    final transcript = [
      const AgentConversationItem.text(role: 'user', content: 'run it'),
      AgentConversationItem.assistantToolCalls([call]),
      AgentConversationItem.toolResults(const [
        AgentToolResult(
          toolCallId: 'call_stop',
          content: '[Tool interrupted by user]',
          isError: true,
        ),
      ]),
    ];

    final openAi = AgentProviderTools.openAiMessages(transcript);
    expect(openAi[1]['role'], 'assistant');
    expect(openAi[2], {
      'role': 'tool',
      'tool_call_id': 'call_stop',
      'content': '[Tool interrupted by user]',
    });

    final anthropic = AgentProviderTools.anthropicMessages(transcript);
    expect((anthropic[2]['content'] as List).single, {
      'type': 'tool_result',
      'tool_use_id': 'call_stop',
      'content': '[Tool interrupted by user]',
      'is_error': true,
    });

    // Gemini resolves the functionResponse `name` from the preceding tool
    // call's id map, so a backfilled result (which carries only a call id)
    // still serializes a valid transcript.
    final gemini = AgentProviderTools.geminiContents(transcript);
    expect((gemini[2]['parts'] as List).single, {
      'functionResponse': {
        'name': 'bash',
        'response': {
          'tool_call_id': 'call_stop',
          'content': '[Tool interrupted by user]',
          'is_error': true,
        },
      },
    });
  });

  test('backfills an isError result for every dangling multi-call turn', () {
    // Mirrors `_completeInterruptedToolCalls` when the model emitted several
    // shell calls (e.g. `sleep 60 && sleep 60`) and the user stops mid-run:
    // EVERY dangling call gets an isError result, keeping the next provider
    // request valid regardless of how many calls were in flight.
    final call1 = AgentToolCall.fromRaw(
      id: 'call_1',
      name: 'bash',
      arguments: const {'command': 'sleep 60'},
    )!;
    final call2 = AgentToolCall.fromRaw(
      id: 'call_2',
      name: 'bash',
      arguments: const {'command': 'sleep 60'},
    )!;
    final transcript = [
      const AgentConversationItem.text(role: 'user', content: 'run both'),
      AgentConversationItem.assistantToolCalls([call1, call2]),
      AgentConversationItem.toolResults(const [
        AgentToolResult(
          toolCallId: 'call_1',
          content: '[Tool interrupted by user]',
          isError: true,
        ),
        AgentToolResult(
          toolCallId: 'call_2',
          content: '[Tool interrupted by user]',
          isError: true,
        ),
      ]),
    ];

    final openAi = AgentProviderTools.openAiMessages(transcript);
    final toolMessages = openAi
        .where((message) => message['role'] == 'tool')
        .toList();
    expect(toolMessages, hasLength(2));
    expect(toolMessages[0]['tool_call_id'], 'call_1');
    expect(toolMessages[1]['tool_call_id'], 'call_2');

    final anthropic = AgentProviderTools.anthropicMessages(transcript);
    final anthropicBlocks = anthropic[2]['content'] as List;
    expect(anthropicBlocks, hasLength(2));
    expect((anthropicBlocks[0] as Map)['tool_use_id'], 'call_1');
    expect((anthropicBlocks[1] as Map)['tool_use_id'], 'call_2');
    expect((anthropicBlocks[0] as Map)['is_error'], true);
    expect((anthropicBlocks[1] as Map)['is_error'], true);

    final gemini = AgentProviderTools.geminiContents(transcript);
    final geminiParts = gemini[2]['parts'] as List;
    expect(geminiParts, hasLength(2));
    expect(
      ((geminiParts[0] as Map)['functionResponse'] as Map)['name'],
      'bash',
    );
    expect(
      ((geminiParts[1] as Map)['functionResponse'] as Map)['name'],
      'bash',
    );
  });

  test('preserves every tool call from one assistant turn', () {
    final calls = [
      AgentToolCall.fromRaw(
        id: 'call_1',
        name: 'bash',
        arguments: const {'command': 'pwd'},
      )!,
      AgentToolCall.fromRaw(
        id: 'call_2',
        name: 'bash',
        arguments: const {'command': 'ls'},
      )!,
    ];

    final messages = AgentProviderTools.openAiMessages([
      AgentConversationItem.assistantToolCalls(calls, content: 'Checking.'),
      AgentConversationItem.toolResults(const [
        AgentToolResult(toolCallId: 'call_1', content: '/tmp'),
        AgentToolResult(toolCallId: 'call_2', content: 'a.txt'),
      ]),
    ]);

    expect(messages[0]['content'], 'Checking.');
    expect(messages[0]['tool_calls'], hasLength(2));
    expect(
      messages.where((message) => message['role'] == 'tool'),
      hasLength(2),
    );
  });

  test('parses an OpenAI native tool call', () {
    final calls = AgentProviderTools.parseOpenAiToolCalls({
      'choices': [
        {
          'message': {
            'tool_calls': [
              {
                'id': 'call_1',
                'function': {'name': 'bash', 'arguments': '{"command":"pwd"}'},
              },
            ],
          },
        },
      ],
    });

    expect(calls.single.name, 'bash');
    expect(calls.single.arguments['command'], 'pwd');
  });

  test('parses Anthropic tool_use blocks', () {
    final calls = AgentProviderTools.parseAnthropicToolCalls({
      'content': [
        {
          'type': 'tool_use',
          'id': 'call_2',
          'name': 'web_search',
          'input': {'query': 'Dart 3.11'},
        },
      ],
    });

    expect(calls.single.name, 'web_search');
    expect(calls.single.arguments['query'], 'Dart 3.11');
  });

  test('parses Gemini functionCall parts', () {
    final calls = AgentProviderTools.parseGeminiToolCalls({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'functionCall': {
                  'name': 'bash',
                  'args': {'command': 'pwd'},
                },
              },
            ],
          },
        },
      ],
    });

    expect(calls.single.name, 'bash');
    expect(calls.single.arguments['command'], 'pwd');
  });

  test('parses a Gemini function-call thought signature', () {
    final calls = AgentProviderTools.parseGeminiToolCalls({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'functionCall': {
                  'name': 'bash',
                  'args': {'command': 'pwd'},
                },
                'thoughtSignature': 'encrypted-signature',
              },
            ],
          },
        },
      ],
    });

    expect(calls.single.thoughtSignature, 'encrypted-signature');
  });
}
