import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_provider_tools.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';
import 'package:ssterm/models/mcp_server_config.dart';

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
}
