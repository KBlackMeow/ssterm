import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';
import 'package:ssterm/models/mcp_server_config.dart';

void main() {
  group('AgentToolRegistry', () {
    test('focused registry retains core tools and filters optional tools', () {
      final registry = AgentToolRegistry.build(
        webSearchEnabled: true,
        fileWriteEnabled: true,
      ).limitedTo({'bash'});

      expect(registry.names, containsAll(['bash', 'ask_user_question']));
      expect(registry.names, isNot(contains('web_search')));
      expect(registry.names, isNot(contains('write_file')));
      expect(registry.names, isNot(contains('edit_file')));
    });

    test('always exposes shell and structured user-question tools', () {
      final registry = AgentToolRegistry.build();

      expect(registry.names, containsAll(['bash', 'ask_user_question']));
      final schema = registry.byName('bash')!.toJsonSchema();
      expect(
        schema['required'],
        containsAll(['command', 'risk_level', 'risk_reason']),
      );
      final properties = schema['properties']! as Map<String, Object>;
      expect(
        properties['risk_level'],
        containsPair('enum', ['normal', 'warning', 'dangerous']),
      );
    });

    test('does not expose disabled optional tools', () {
      final registry = AgentToolRegistry.build();

      expect(registry.names, isNot(contains('web_search')));
      expect(registry.names, isNot(contains('write_file')));
      expect(registry.names, isNot(contains('edit_file')));
      expect(registry.names, isNot(contains('use_skill')));
    });

    test('exposes schemas for enabled web and file capabilities', () {
      final registry = AgentToolRegistry.build(
        webSearchEnabled: true,
        fileWriteEnabled: true,
      );

      expect(registry.byName('web_search')!.toJsonSchema()['required'], [
        'query',
      ]);
      expect(registry.byName('write_file')!.toJsonSchema()['required'], [
        'path',
        'content',
      ]);
      expect(registry.byName('edit_file')!.toJsonSchema()['required'], [
        'path',
        'old_string',
        'new_string',
      ]);
    });
  });

  test('exposes each connected MCP tool with its discovered schema', () {
    final registry = AgentToolRegistry.build(
      mcpTools: const [
        McpTool(
          serverId: 'demo',
          serverName: 'Demo',
          name: 'echo',
          description: 'Echo text',
          inputSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        ),
        McpTool(
          serverId: 'demo',
          serverName: 'Demo',
          name: 'status',
          description: 'Read status',
          inputSchema: {'type': 'object', 'properties': {}},
        ),
      ],
    );

    expect(
      registry.names,
      containsAll(['mcp__demo__echo', 'mcp__demo__status']),
    );
    expect(registry.names, isNot(contains('mcp')));
    expect(registry.byName('mcp__demo__echo')!.description, 'Echo text');
    expect(registry.byName('mcp__demo__echo')!.toJsonSchema(), {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    });
  });

  test('normalizes a native MCP tool call for the existing executor', () {
    final registry = AgentToolRegistry.build(
      mcpTools: const [
        McpTool(
          serverId: 'matrix',
          serverName: 'Matrix',
          name: 'send_message',
          description: 'Send a Matrix message',
          inputSchema: {'type': 'object'},
        ),
      ],
    );
    final nativeCall = AgentToolCall.fromRaw(
      id: 'call_1',
      name: 'mcp__matrix__send_message',
      arguments: {'room_id': '!room:example.org', 'text': 'hello'},
    )!;

    final call = registry.normalizeToolCall(nativeCall);

    expect(call.name, 'mcp');
    expect(call.arguments, {
      'server': 'matrix',
      'tool': 'send_message',
      'params': {'room_id': '!room:example.org', 'text': 'hello'},
    });
  });

  test('makes invalid or long MCP names provider-safe and routable', () {
    final registry = AgentToolRegistry.build(
      mcpTools: const [
        McpTool(
          serverId: 'matrix.prod',
          serverName: 'Matrix',
          name:
              'send/message-with-a-name-that-is-far-too-long-for-provider-function-limits',
          description: '',
          inputSchema: {'type': 'object'},
        ),
      ],
    );

    final nativeName = registry.names.singleWhere(
      (name) => name.startsWith('mcp__'),
    );
    expect(nativeName, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(nativeName.length, lessThanOrEqualTo(64));

    final call = registry.normalizeToolCall(
      AgentToolCall.fromRaw(
        id: 'call_2',
        name: nativeName,
        arguments: const {},
      )!,
    );
    expect(call.name, 'mcp');
    expect(call.arguments['server'], 'matrix.prod');
    expect(
      call.arguments['tool'],
      'send/message-with-a-name-that-is-far-too-long-for-provider-function-limits',
    );
  });
}
