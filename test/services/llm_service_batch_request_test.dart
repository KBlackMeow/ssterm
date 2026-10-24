import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/agent_stream_client_session.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/llm_service.dart';

void main() {
  for (final protocol in [
    ProviderProtocol.openAiCompatible,
    ProviderProtocol.anthropicCompatible,
  ]) {
    for (final streaming in [false, true]) {
      test(
        '${protocol.name} ${streaming ? 'stream' : 'chat'} permits multiple calls without a single-call override',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final requests = <Map<String, dynamic>>[];
          final config = AgentConfig(
            defaultProvider: 'fixture',
            defaultModel: 'fixture-model',
            providers: [
              ProviderConfig(
                id: 'fixture',
                displayName: 'Fixture',
                enabled: true,
                protocol: protocol,
                baseUrl: 'http://127.0.0.1:${server.port}',
                models: const ['fixture-model'],
                requiresApiKey: false,
              ),
            ],
          );
          final calls = [
            {
              'id': 'read',
              'name': 'read_file',
              'arguments': {'path': '/a', 'offset': 0},
            },
            {
              'id': 'shell',
              'name': 'bash',
              'arguments': {
                'command': 'pwd',
                'reason': 'Inspect',
                'risk_level': 'normal',
                'risk_reason': 'Read only',
              },
            },
          ];
          server.listen((request) async {
            requests.add(
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>,
            );
            if (streaming) {
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
              );
            }
            if (protocol == ProviderProtocol.openAiCompatible) {
              final native = [
                for (var i = 0; i < calls.length; i++)
                  {
                    if (streaming) 'index': i,
                    'id': calls[i]['id'],
                    'type': 'function',
                    'function': {
                      'name': calls[i]['name'],
                      'arguments': jsonEncode(calls[i]['arguments']),
                    },
                  },
              ];
              final body = {
                'choices': [
                  {
                    streaming ? 'delta' : 'message': {
                      'role': 'assistant',
                      'content': '',
                      'tool_calls': native,
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
              };
              request.response.write(
                streaming
                    ? 'data: ${jsonEncode(body)}\n\ndata: [DONE]\n\n'
                    : jsonEncode(body),
              );
            } else if (streaming) {
              void emit(Map<String, Object?> event) =>
                  request.response.write('data: ${jsonEncode(event)}\n\n');
              for (var i = 0; i < calls.length; i++) {
                emit({
                  'type': 'content_block_start',
                  'index': i,
                  'content_block': {
                    'type': 'tool_use',
                    'id': calls[i]['id'],
                    'name': calls[i]['name'],
                    'input': <String, Object?>{},
                  },
                });
                emit({
                  'type': 'content_block_delta',
                  'index': i,
                  'delta': {
                    'type': 'input_json_delta',
                    'partial_json': jsonEncode(calls[i]['arguments']),
                  },
                });
                emit({'type': 'content_block_stop', 'index': i});
              }
              emit({
                'type': 'message_delta',
                'delta': {'stop_reason': 'tool_use'},
              });
              emit({'type': 'message_stop'});
            } else {
              request.response.write(
                jsonEncode({
                  'content': [
                    for (final call in calls)
                      {
                        'type': 'tool_use',
                        'id': call['id'],
                        'name': call['name'],
                        'input': call['arguments'],
                      },
                  ],
                  'stop_reason': 'tool_use',
                }),
              );
            }
            await request.response.close();
          });
          final List<AgentToolCall> parsed;
          if (streaming) {
            final session = AgentStreamClientSession();
            try {
              final events = await LlmService.chatStream(
                config: config,
                messages: const [],
                session: session,
              ).stream.toList();
              parsed = events
                  .map((event) => event.toolCall)
                  .whereType<AgentToolCall>()
                  .toList();
            } finally {
              session.close();
            }
          } else {
            final response = await LlmService.chat(
              config: config,
              messages: const [],
            );
            expect(response.error, isNull);
            parsed = response.toolCalls;
          }
          expect(parsed.map((call) => call.id), ['read', 'shell']);
          final request = requests.single;
          expect(request['tools'], isNotEmpty);
          expect(request.containsKey('parallel_tool_calls'), isFalse);
          if (protocol == ProviderProtocol.anthropicCompatible) {
            expect(request['tool_choice'], {'type': 'auto'});
          }
        },
      );
    }
  }
}
