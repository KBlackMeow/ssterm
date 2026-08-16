import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/widgets/ai_assistant_panel.dart';

/// Regression test for the "agent stops auto-following the latest content
/// after several replies" bug.
///
/// The agent loop inserts an empty assistant card (a placeholder with an icon
/// but no text) at the start of every LLM call WITHOUT scrolling to it.  That
/// empty card is ~36px tall, so the next `_scrollToBottom` from the streaming
/// path used to see a >24px gap, decide "the user scrolled away", and disable
/// following for the rest of the turn — and every turn after it.  Following
/// must instead be paused ONLY by a genuine user scroll.
void main() {
  testWidgets(
    'streamed agent replies keep the transcript pinned to the bottom',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final sse = <String>[];
      for (var i = 0; i < 40; i++) {
        sse.add(
          'data: {"choices":[{"delta":{"content":'
          '"line $i of a long agent reply that wraps and grows the transcript. "}}]}',
        );
      }
      sse.add('data: {"choices":[{"delta":{"content":"[TASK_COMPLETE]"}}]}');
      sse.add('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}');
      sse.add('data: [DONE]');

      final overrides = _MockHttpOverrides(sse);
      HttpOverrides.global = overrides;
      addTearDown(() => HttpOverrides.global = null);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiAssistantOverlay(
              visible: true,
              initialPosition: AiPanelPosition.bottom,
              agentConfig: _fakeAgentConfig(),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.tap(find.byIcon(Icons.send_rounded));

      // Let the whole streamed reply drain.  The stream emits one chunk per
      // 5ms of fake time; 120 × 10ms is more than enough to cover the stream,
      // the empty-card layout, and every auto-scroll animation.
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      // The reply has no tool calls, so no status spinner is ever shown and
      // the turn ends cleanly — pumpAndSettle can finish.
      await tester.pumpAndSettle();

      final position = tester
          .widget<ListView>(find.byType(ListView))
          .controller!
          .position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: 'the long reply should overflow the panel',
      );
      expect(
        position.maxScrollExtent - position.pixels,
        lessThan(1.0),
        reason: 'the transcript must stay pinned to the latest content',
      );
    },
  );
}

AgentConfig _fakeAgentConfig() {
  final provider = ProviderConfig(
    id: 'fake-openai',
    displayName: 'Fake OpenAI',
    protocol: ProviderProtocol.openAiCompatible,
    enabled: true,
    baseUrl: 'http://127.0.0.1:9/v1',
    models: const ['fake-model'],
    requiresApiKey: false,
  );
  return AgentConfig(
    defaultProvider: provider.id,
    defaultModel: 'fake-model',
    providers: [provider],
    fileWriteEnabled: false,
  );
}

class _MockHttpOverrides extends HttpOverrides {
  _MockHttpOverrides(this.sse);
  final List<String> sse;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _MockHttpClient(sse);
}

class _MockHttpClient implements HttpClient {
  _MockHttpClient(this.sse);
  final List<String> sse;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _MockRequest(sse);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClient.${invocation.memberName}');
}

class _MockRequest implements HttpClientRequest {
  _MockRequest(this.sse);
  final List<String> sse;

  @override
  HttpHeaders get headers => _MockHeaders();

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() async => _MockResponse(_sseStream());

  Stream<List<int>> _sseStream() async* {
    for (final event in sse) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield utf8.encode('$event\n\n');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClientRequest.${invocation.memberName}');
}

class _MockHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpHeaders.${invocation.memberName}');
}

class _MockResponse implements HttpClientResponse {
  _MockResponse(this._stream);
  final Stream<List<int>> _stream;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Stream<R> transform<R>(StreamTransformer<List<int>, R> transformer) =>
      _stream.transform(transformer);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClientResponse.${invocation.memberName}');
}
