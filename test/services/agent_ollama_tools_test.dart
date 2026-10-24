import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/agent_stream_client_session.dart';
import 'package:ssterm/services/agent_tool_batch.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';
import 'package:ssterm/services/llm_service.dart';

const _arguments = {
  'command': 'pwd',
  'reason': 'Find current directory',
  'risk_level': 'normal',
  'risk_reason': 'Read only',
};
Map<String, Object> _call(String name, Map<String, Object> arguments) => {
  'function': {'name': name, 'arguments': arguments},
};

AgentConfig _config(String baseUrl) => AgentConfig(
  defaultProvider: 'ollama-test',
  defaultModel: 'test-model',
  providers: [
    ProviderConfig(
      id: 'ollama-test',
      displayName: 'Ollama test',
      protocol: ProviderProtocol.ollamaNative,
      baseUrl: baseUrl,
      models: const ['test-model'],
      enabled: true,
      requiresApiKey: false,
    ),
  ],
);

Future<List<LlmStreamEvent>> _stream(
  AgentConfig config, {
  List<AgentConversationItem> messages = const [],
}) async {
  final session = AgentStreamClientSession();
  try {
    return await LlmService.chatStream(
      config: config,
      messages: messages,
      session: session,
    ).stream.toList();
  } finally {
    session.close();
  }
}

void main() {
  late HttpServer server;
  late AgentConfig config;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    config = _config('http://127.0.0.1:${server.port}');
  });
  tearDown(() => server.close(force: true));

  test(
    'non-streaming advertises tools and parses native object arguments',
    () async {
      server.listen((request) async {
        expect(request.uri.path, '/api/chat');
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['stream'], isFalse);
        final tools = body['tools'] as List;
        final bash = (tools.first as Map)['function'] as Map;
        expect(bash['name'], 'bash');
        expect(bash.containsKey('strict'), isFalse);
        expect(
          (bash['parameters'] as Map)['required'],
          contains('risk_reason'),
        );
        final prompt =
            ((body['messages'] as List).first as Map)['content'] as String;
        expect(prompt, isNot(contains('```tool_call')));
        request.response.write(
          jsonEncode({
            'message': {
              'content': '',
              'tool_calls': [_call('bash', _arguments)],
            },
            'done': true,
            'done_reason': 'stop',
          }),
        );
        await request.response.close();
      });
      final response = await LlmService.chat(
        config: config,
        messages: const [],
      );
      expect(response.error, isNull);
      expect(response.toolCalls.single.arguments, _arguments);
      expect(
        AgentToolBatch.rejectionReason(
          response.toolCalls,
          AgentToolRegistry.build(),
        ),
        isNull,
      );
    },
  );

  test(
    'streaming preserves thinking and multiple calls across chunks',
    () async {
      var requests = 0;
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        requests++;
        expect(body['tools'], isNotEmpty);
        if (requests == 1) {
          for (final chunk in [
            {
              'message': {'thinking': 'Inspecting current directory'},
            },
            {
              'message': {
                'content': '',
                'tool_calls': [_call('bash', _arguments)],
              },
            },
            {
              'message': {
                'tool_calls': [
                  _call('read_file', {'path': '/tmp/example', 'offset': 0}),
                ],
              },
            },
            {
              'done': true,
              'done_reason': 'stop',
              'prompt_eval_count': 40,
              'eval_count': 12,
            },
          ]) {
            request.response.writeln(jsonEncode(chunk));
          }
        } else {
          final messages = body['messages'] as List;
          final assistant =
              messages.firstWhere((message) => message['role'] == 'assistant')
                  as Map;
          expect(assistant['thinking'], 'Inspecting current directory');
          expect(assistant['content'], '');
          final calls = assistant['tool_calls'] as List;
          expect(calls, hasLength(2));
          expect(calls.first['function']['arguments'], _arguments);
          final results = messages
              .where((message) => message['role'] == 'tool')
              .toList();
          expect(results.map((message) => message['tool_name']), [
            'bash',
            'read_file',
          ]);
          expect(results.map((message) => message['content']), [
            '/workspace',
            'example',
          ]);
          request.response.writeln(
            jsonEncode({
              'message': {'content': 'Done'},
              'done': true,
            }),
          );
        }
        await request.response.close();
      });
      final events = await _stream(config);
      final calls = events
          .map((event) => event.toolCall)
          .whereType<AgentToolCall>()
          .toList();
      expect(calls.map((call) => call.name), ['bash', 'read_file']);
      expect(calls.map((call) => call.id).toSet(), hasLength(2));
      expect(events.last.promptTokenCount, 40);
      expect(events.last.completionTokenCount, 12);
      final continued = await _stream(
        config,
        messages: [
          AgentConversationItem.assistantToolCalls(
            calls,
            reasoningContent: 'Inspecting current directory',
          ),
          AgentConversationItem.toolResults([
            AgentToolResult(toolCallId: calls[0].id, content: '/workspace'),
            AgentToolResult(toolCallId: calls[1].id, content: 'example'),
          ]),
        ],
      );
      expect(
        continued.where((event) => event.kind == 'text').single.content,
        'Done',
      );
    },
  );

  test('unsupported tools fail without retrying a text protocol', () async {
    var requests = 0;
    server.listen((request) async {
      await request.drain<void>();
      requests++;
      request.response.statusCode = 400;
      request.response.write(
        jsonEncode({'error': 'test-model does not support tools'}),
      );
      await request.response.close();
    });
    await expectLater(_stream(config), throwsA(isA<LlmHttpException>()));
    expect(requests, 1);
  });

  const simulationUrl = String.fromEnvironment('OLLAMA_TEST_BASE_URL');
  test(
    'native client completes a tool round trip against Postman simulation',
    () async {
      final simulationConfig = _config(simulationUrl);
      final response = await LlmService.chat(
        config: simulationConfig,
        messages: const [],
      );
      expect(response.error, isNull);
      expect(response.toolCalls.single.name, 'bash');
      final calls = response.toolCalls;
      final events = await _stream(
        simulationConfig,
        messages: [
          AgentConversationItem.assistantToolCalls(calls),
          AgentConversationItem.toolResults([
            AgentToolResult(toolCallId: calls.single.id, content: '/workspace'),
          ]),
        ],
      );
      expect(
        events
            .where((event) => event.kind == 'text')
            .map((event) => event.content)
            .join(),
        'Directory: /workspace',
      );
    },
    skip: simulationUrl.isEmpty
        ? 'Set OLLAMA_TEST_BASE_URL to the local Postman simulation URL.'
        : false,
  );
}
