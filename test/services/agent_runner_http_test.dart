import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/agent_context_budget.dart';
import 'package:ssterm/services/agent_model.dart';
import 'package:ssterm/services/agent_runner.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';

AgentConfig _config(String baseUrl, {bool ollama = false}) => AgentConfig(
  defaultProvider: 'fixture',
  defaultModel: 'fixture-model',
  providers: [
    ProviderConfig(
      id: 'fixture',
      displayName: 'Fixture',
      enabled: true,
      protocol: ollama
          ? ProviderProtocol.ollamaNative
          : ProviderProtocol.openAiCompatible,
      baseUrl: baseUrl,
      models: const ['fixture-model'],
      requiresApiKey: false,
    ),
  ],
);

AgentRunner _runner(AgentConfig config, {List<String>? executed}) =>
    AgentRunner(
      history: AgentConversationHistory()
        ..add(
          AgentConversationItem.text(
            role: 'user',
            content: 'Find the working directory',
          ),
        ),
      model: LlmAgentModel(config),
      registry: AgentToolRegistry.build,
      contextBudget: AgentContextBudget.forContextWindow(128000),
      executeTool: (call, _) async {
        executed?.add(call.id);
        return AgentToolExecution.completed(
          AgentToolResult(toolCallId: call.id, content: '/workspace'),
        );
      },
      delay: (_) async {},
    );

void main() {
  test(
    'real HTTP runner retries 429 and replays a mixed batch in original order',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        expect(request.uri.path, '/v1/chat/completions');
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        if (requests.length == 1) {
          request.response.statusCode = 429;
          request.response.write('{"error":{"message":"Rate limited"}}');
        } else {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          final toolResult = (requests.last['messages'] as List).where(
            (m) => m['role'] == 'tool',
          );
          final delta = toolResult.isEmpty
              ? {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'read',
                      'type': 'function',
                      'function': {
                        'name': 'read_file',
                        'arguments': jsonEncode({'path': '/a', 'offset': 0}),
                      },
                    },
                    {
                      'index': 1,
                      'id': 'directory',
                      'type': 'function',
                      'function': {
                        'name': 'bash',
                        'arguments': jsonEncode({
                          'command': 'pwd',
                          'reason': 'Inspect',
                          'risk_level': 'normal',
                          'risk_reason': 'Read only',
                        }),
                      },
                    },
                  ],
                }
              : {'content': 'Directory: ${toolResult.last['content']}'};
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {'delta': delta, 'finish_reason': toolResult.isEmpty ? 'tool_calls' : 'stop'},
              ],
            })}\n\ndata: [DONE]\n\n',
          );
        }
        await request.response.close();
      });
      final executed = <String>[];
      final runner = _runner(
        _config('http://127.0.0.1:${server.port}/v1'),
        executed: executed,
      );
      final events = <AgentRunnerEvent>[];
      runner.subscribe(events.add);
      await runner.run();
      expect(runner.state, AgentRunState.completed);
      expect(requests, hasLength(3));
      final messages = requests.last['messages'] as List;
      final results = messages.where((m) => m['role'] == 'tool').toList();
      expect(executed, ['read', 'directory']);
      expect(results.map((r) => r['tool_call_id']), ['read', 'directory']);
      final result = results.last;
      expect(result['tool_call_id'], 'directory');
      expect(result['content'], '/workspace');
      expect(runner.history.last.content, 'Directory: /workspace');
      expect(
        events.whereType<AgentStatusChanged>().any(
          (e) => e.text?.contains('Rate limited') ?? false,
        ),
        isTrue,
      );
    },
  );

  const simulationUrl = String.fromEnvironment('OLLAMA_TEST_BASE_URL');
  test(
    'headless runner completes a native tool round trip against Postman simulation',
    () async {
      final runner = _runner(_config(simulationUrl, ollama: true));
      await runner.run();
      expect(runner.state, AgentRunState.completed);
      expect(runner.history.last.content, contains('/workspace'));
      expect(
        runner.history.where((item) => item.toolResults.isNotEmpty),
        hasLength(1),
      );
    },
    skip: simulationUrl.isEmpty
        ? 'Set OLLAMA_TEST_BASE_URL to run Postman simulation.'
        : false,
  );
}
