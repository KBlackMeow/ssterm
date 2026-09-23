import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/agent_stream_client_session.dart';
import 'package:ssterm/services/llm_service.dart';

/// Wire-shape tests for `AgentRequestProfile.jsonMode`: every protocol path
/// must ask for guaranteed JSON through its own native mechanism and degrade
/// gracefully when an endpoint rejects the parameter.
void main() {
  late HttpServer server;
  final requests = <Map<String, dynamic>>[];

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  AgentConfig configFor(ProviderProtocol protocol) {
    final provider = ProviderConfig(
      id: 'test-${protocol.name}',
      displayName: 'test',
      protocol: protocol,
      enabled: true,
      baseUrl: 'http://127.0.0.1:${server.port}',
      models: const ['test-model'],
      requiresApiKey: false,
    );
    return AgentConfig(
      defaultProvider: provider.id,
      defaultModel: 'test-model',
      providers: [provider],
      fileWriteEnabled: false,
    );
  }

  /// Serves [handler] for one request at a time and records decoded bodies.
  void serve(Future<void> Function(HttpRequest) handler) {
    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      await handler(request);
      await request.response.close();
    });
  }

  const jsonProfile = AgentRequestProfile(
    systemPromptOverride: 'Return one JSON object only.',
    allowedNativeToolNames: {},
    jsonMode: true,
  );

  Future<String> streamText(AgentConfig config) async {
    final session = AgentStreamClientSession();
    final text = StringBuffer();
    try {
      final call = LlmService.chatStream(
        config: config,
        messages: const [],
        session: session,
        profile: jsonProfile,
      );
      await for (final event in call.stream) {
        if (event.kind == 'text') text.write(event.content);
      }
    } finally {
      session.close();
    }
    return text.toString();
  }

  test(
    'openai-compatible jsonMode sends response_format json_object',
    () async {
      serve((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.parse(
          'text/event-stream',
        );
        const payload = '{"answer":"ok"}';
        request.response.add(
          utf8.encode(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': payload},
                },
              ],
            })}\n\n'
            'data: [DONE]\n\n',
          ),
        );
      });

      final text = await streamText(
        configFor(ProviderProtocol.openAiCompatible),
      );

      expect(text, '{"answer":"ok"}');
      expect(requests.single['response_format'], {'type': 'json_object'});
    },
  );

  test(
    'openai-compatible retries without response_format after a 400',
    () async {
      var calls = 0;
      serve((request) async {
        calls++;
        if (calls == 1) {
          request.response.statusCode = 400;
          request.response.add(
            utf8.encode('{"error":{"message":"response_format unsupported"}}'),
          );
          return;
        }
        expect(requests.last.containsKey('response_format'), isFalse);
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.parse(
          'text/event-stream',
        );
        request.response.add(
          utf8.encode(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '{"answer":"plain"}'},
                },
              ],
            })}\n\n'
            'data: [DONE]\n\n',
          ),
        );
      });

      final text = await streamText(
        configFor(ProviderProtocol.openAiCompatible),
      );

      expect(text, '{"answer":"plain"}');
      expect(calls, 2);
      expect(requests.first.containsKey('response_format'), isTrue);
      expect(requests.last.containsKey('response_format'), isFalse);
    },
  );

  test(
    'anthropic jsonMode prefills {, disables thinking, restores the brace',
    () async {
      serve((request) async {
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.parse(
          'text/event-stream',
        );
        request.response.add(
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': '"answer":"ok"}'},
            })}\n\n'
            'data: ${jsonEncode({'type': 'message_stop'})}\n\n',
          ),
        );
      });

      final thinkingProfile = AgentRequestProfile(
        systemPromptOverride: 'Return one JSON object only.',
        allowedNativeToolNames: {},
        reasoningLevel: AgentReasoningLevel.medium,
        jsonMode: true,
      );
      final session = AgentStreamClientSession();
      final text = StringBuffer();
      try {
        final call = LlmService.chatStream(
          config: configFor(ProviderProtocol.anthropicCompatible),
          messages: const [],
          session: session,
          // A thinking-capable model name proves jsonMode gates the parameter.
          profile: thinkingProfile,
        );
        await for (final event in call.stream) {
          if (event.kind == 'text') text.write(event.content);
        }
      } finally {
        session.close();
      }

      expect(text.toString(), '{"answer":"ok"}');
      final body = requests.single;
      expect(body['model'], 'test-model');
      // Prefill rides as the trailing assistant turn…
      expect((body['messages'] as List).last, {
        'role': 'assistant',
        'content': '{',
      });
      // …and extended thinking (incompatible with prefill) stays off.
      expect(body.containsKey('thinking'), isFalse);
    },
  );

  test('gemini jsonMode sets responseMimeType application/json', () async {
    serve((request) async {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.parse(
        'text/event-stream',
      );
      request.response.add(
        utf8.encode(
          'data: ${jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '{"answer":"ok"}'},
                  ],
                },
              },
            ],
          })}\n\n',
        ),
      );
    });

    final text = await streamText(configFor(ProviderProtocol.geminiNative));

    expect(text, '{"answer":"ok"}');
    expect(
      requests.single['generationConfig']['responseMimeType'],
      'application/json',
    );
  });

  test('ollama jsonMode sends format json', () async {
    serve((request) async {
      request.response.statusCode = 200;
      request.response.add(
        utf8.encode(
          '${jsonEncode({
            'message': {'content': '{"answer":"ok"}'},
          })}\n',
        ),
      );
    });

    final text = await streamText(configFor(ProviderProtocol.ollamaNative));

    expect(text, '{"answer":"ok"}');
    expect(requests.single['format'], 'json');
  });

  test('jsonMode off leaves every request body unchanged', () async {
    serve((request) async {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.parse(
        'text/event-stream',
      );
      request.response.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'plain'},
              },
            ],
          })}\n\n'
          'data: [DONE]\n\n',
        ),
      );
    });

    final session = AgentStreamClientSession();
    final call = LlmService.chatStream(
      config: configFor(ProviderProtocol.openAiCompatible),
      messages: const [],
      session: session,
      profile: const AgentRequestProfile(
        systemPromptOverride: 'plain',
        allowedNativeToolNames: {},
      ),
    );
    await call.stream.toList();
    session.close();

    expect(requests.single.containsKey('response_format'), isFalse);
  });
}
