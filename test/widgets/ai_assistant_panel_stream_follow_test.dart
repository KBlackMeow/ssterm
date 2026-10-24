import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/io/output_pipe.dart';
import 'package:ssterm/models/agent_config.dart';
import 'package:ssterm/services/file_write_service.dart';
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
  testWidgets('text tool fences and action markers never execute', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForText('''```tool_call
{"id":"text_shell","name":"bash","arguments":{"command":"pwd","reason":"Inspect","risk_level":"normal","risk_reason":"Read only"}}
```
[USE_SKILL: nonexistent]
[WEB_SEARCH: example]
[WRITE_FILE_BEGIN: /fixture/result.txt]
should not be written
[WRITE_FILE_END]
'''),
    ]);
    HttpOverrides.global = http;
    addTearDown(() => HttpOverrides.global = null);
    final files = _MemoryFileSystemAdapter();
    final executed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAssistantOverlay(
            visible: true,
            initialPosition: AiPanelPosition.bottom,
            agentConfig: _fakeAgentConfig().copyWith(fileWriteEnabled: true),
            fileSystemAdapter: files,
            onExecuteAsync: (cmd, {isCancelled, onUpdate, onSilence}) async {
              executed.add(cmd);
              return CommandResult(output: '', exitCode: 0);
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Inspect the directory');
    await tester.tap(find.byIcon(Icons.send_rounded));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(executed, isEmpty);
    expect(files.writtenContent, isNull);
    expect(find.text('Apply'), findsNothing);
    expect(http.requestBodies, hasLength(1));
  });

  testWidgets('approved native write resumes with a paired tool result', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForToolCalls([
        {
          'index': 0,
          'id': 'call_write',
          'function': {
            'name': 'write_file',
            'arguments': jsonEncode({
              'path': '/fixture/result.txt',
              'content': 'COPPER-19\n',
            }),
          },
        },
      ]),
      _sseForText('The file was created. [TASK_COMPLETE]'),
    ]);
    HttpOverrides.global = http;
    addTearDown(() => HttpOverrides.global = null);
    final files = _MemoryFileSystemAdapter();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAssistantOverlay(
            visible: true,
            initialPosition: AiPanelPosition.bottom,
            agentConfig: _fakeAgentConfig().copyWith(fileWriteEnabled: true),
            fileSystemAdapter: files,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Create result.txt');
    await tester.tap(find.byIcon(Icons.send_rounded));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('Apply'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();

    expect(files.writtenContent, 'COPPER-19\n');
    expect(http.requestBodies, hasLength(2));
    final second = jsonDecode(http.requestBodies.last) as Map<String, dynamic>;
    final messages = second['messages'] as List<dynamic>;
    expect(
      messages.any(
        (message) =>
            message is Map &&
            message['role'] == 'tool' &&
            message['tool_call_id'] == 'call_write',
      ),
      isTrue,
    );
  });

  testWidgets('approved native edit resumes its original tool call', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForToolCalls([
        _nativeCall('edit', 'edit_file', {
          'path': '/fixture/sample.txt',
          'old_string': 'target',
          'new_string': 'updated',
        }),
      ]),
      _sseForText('Edited.'),
    ]);
    final files = _MemoryFileSystemAdapter();
    await _mountAgent(tester, http, files);
    await _sendTask(tester, 'Edit the marker');
    expect(find.text('Apply'), findsOneWidget);
    await tester.ensureVisible(find.text('Apply'));
    await tester.tap(find.text('Apply'));
    await _drainAgent(tester);
    expect(files.writtenContent, 'updated marker\n');
    expect(_lastToolResult(http)['tool_call_id'], 'edit');
    expect(http.requestBodies, hasLength(2));
  });

  testWidgets(
    'mixed batch resumes after each approval without reordering tools',
    (tester) async {
      final http = _QueuedHttpOverrides([
        _sseForToolCalls([
          _nativeCall('read', 'read_file', {
            'path': '/fixture/sample.txt',
            'offset': 0,
          }),
          _nativeCall('write_one', 'write_file', {
            'path': '/fixture/one',
            'content': 'one',
          }, index: 1),
          _nativeCall('write_two', 'write_file', {
            'path': '/fixture/two',
            'content': 'two',
          }, index: 2),
          _nativeCall('shell', 'bash', {
            'command': 'pwd',
            'reason': 'Inspect',
            'risk_level': 'normal',
            'risk_reason': 'Read only',
          }, index: 3),
        ]),
        _sseForText('Batch finished.'),
      ]);
      final files = _MemoryFileSystemAdapter();
      final executed = <String>[];
      await _mountAgent(tester, http, files, executed: executed);
      await _sendTask(
        tester,
        'Read the sample, write the supplied files and run pwd',
      );
      expect(files.writtenContents, isEmpty);
      expect(executed, isEmpty);
      expect(http.requestBodies, hasLength(1));
      await tester.ensureVisible(find.text('Apply'));
      await tester.tap(find.text('Apply'));
      await _drainAgent(tester);
      expect(files.writtenContents, ['one']);
      expect(executed, isEmpty);
      expect(http.requestBodies, hasLength(1));
      expect(find.text('Apply'), findsOneWidget);
      await tester.ensureVisible(find.text('Apply'));
      await tester.tap(find.text('Apply'));
      await _drainAgent(tester);
      expect(files.writtenContents, ['one', 'two']);
      expect(executed, ['pwd']);
      expect(http.requestBodies, hasLength(2));
      final body = jsonDecode(http.requestBodies.last) as Map;
      final results = (body['messages'] as List).where(
        (m) => m['role'] == 'tool',
      );
      expect(results.map((r) => r['tool_call_id']), [
        'read',
        'write_one',
        'write_two',
        'shell',
      ]);
      expect(find.textContaining('Batch finished.'), findsOneWidget);
    },
  );

  testWidgets(
    'rejecting a file stops the remaining mixed batch and preserves results',
    (tester) async {
      final http = _QueuedHttpOverrides([
        _sseForToolCalls([
          _nativeCall('read', 'read_file', {
            'path': '/fixture/sample.txt',
            'offset': 0,
          }),
          _nativeCall('write', 'write_file', {
            'path': '/fixture/a',
            'content': 'a',
          }, index: 1),
          _nativeCall('later', 'bash', {
            'command': 'pwd',
            'reason': 'Inspect',
            'risk_level': 'normal',
            'risk_reason': 'Read only',
          }, index: 2),
        ]),
        _sseForText('New task.'),
      ]);
      final files = _MemoryFileSystemAdapter();
      final executed = <String>[];
      await _mountAgent(tester, http, files, executed: executed);
      await _sendTask(tester, 'Inspect and propose the supplied file');
      await tester.ensureVisible(find.text('Reject'));
      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('Send rejection')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send rejection'));
      await _drainAgent(tester);
      expect(files.writtenContents, isEmpty);
      expect(executed, isEmpty);
      expect(http.requestBodies, hasLength(1));
      await _sendTask(tester, 'Start a new task');
      final body = jsonDecode(http.requestBodies.last) as Map;
      final results = (body['messages'] as List)
          .where((m) => m['role'] == 'tool')
          .toList();
      expect(results.map((r) => r['tool_call_id']), ['read', 'write', 'later']);
      expect(results.first['content'], contains('target marker'));
      expect(results[1]['content'], contains('rejected'));
      expect(results.last['content'], contains('not executed'));
      expect(executed, isEmpty);
    },
  );

  testWidgets('rejected native write returns rejection without writing', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForToolCalls([
        _nativeCall('write', 'write_file', {
          'path': '/fixture/a',
          'content': 'a',
        }),
      ]),
      _sseForText('Write rejected.'),
    ]);
    final files = _MemoryFileSystemAdapter();
    await _mountAgent(tester, http, files);
    await _sendTask(tester, 'Write a file');
    await tester.ensureVisible(find.text('Reject'));
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('Send rejection')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send rejection'));
    await _drainAgent(tester);
    expect(files.writtenContent, isNull);
    expect(http.requestBodies, hasLength(1));
    await _sendTask(tester, 'Continue with a new task');
    expect(_lastToolResult(http)['tool_call_id'], 'write');
    expect(_lastToolResult(http)['content'], contains('rejected'));
  });

  testWidgets('clearing a paused write discards its task before new input', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForToolCalls([
        _nativeCall('old_write', 'write_file', {
          'path': '/fixture/a',
          'content': 'a',
        }),
      ]),
      _sseForText('Fresh conversation.'),
    ]);
    final files = _MemoryFileSystemAdapter();
    await _mountAgent(tester, http, files);
    await _sendTask(tester, 'Write a file');
    expect(find.text('Apply'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Apply'), findsNothing);
    await _sendTask(tester, 'Start again');
    expect(files.writtenContent, isNull);
    expect(http.requestBodies, hasLength(2));
    expect(http.requestBodies.last, isNot(contains('old_write')));
    expect(find.textContaining('Fresh conversation.'), findsOneWidget);
  });

  testWidgets('late preview after clearing cannot create an approval card', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForToolCalls([
        _nativeCall('write', 'write_file', {
          'path': '/fixture/a',
          'content': 'a',
        }),
      ]),
    ]);
    final preview = Completer<void>();
    final files = _MemoryFileSystemAdapter()..previewWaiter = preview.future;
    await _mountAgent(tester, http, files);
    await _sendTask(tester, 'Write a file');
    await tester.tap(find.byTooltip('Clear conversation'));
    await tester.pumpAndSettle();
    preview.complete();
    await _drainAgent(tester);
    expect(find.text('Apply'), findsNothing);
    expect(files.writtenContent, isNull);
    expect(http.requestBodies, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejecting a dangerous command stops the whole batch', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForToolCalls([
        _nativeCall('danger', 'bash', {
          'command': 'rm -rf /fixture/work',
          'reason': 'Remove files',
          'risk_level': 'dangerous',
          'risk_reason': 'Deletes files',
        }),
        _nativeCall('later', 'bash', {
          'command': 'pwd',
          'reason': 'Inspect',
          'risk_level': 'normal',
          'risk_reason': 'Read only',
        }, index: 1),
      ]),
    ]);
    final executed = <String>[];
    await _mountAgent(
      tester,
      http,
      _MemoryFileSystemAdapter(),
      executed: executed,
    );
    await _sendTask(tester, 'Remove the directory');
    await tester.ensureVisible(find.text('Reject'));
    await tester.tap(find.text('Reject'));
    await _drainAgent(tester);
    expect(executed, isEmpty);
    expect(http.requestBodies, hasLength(1));
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
  });

  testWidgets('question answer returns to runner as paired tool result', (
    tester,
  ) async {
    final http = _QueuedHttpOverrides([
      _sseForToolCalls([
        _nativeCall('question', 'ask_user_question', {
          'question': 'Where should I run?',
          'header': 'Target',
          'options': [
            {'label': 'Use local', 'description': 'This workspace'},
            {'label': 'Use remote', 'description': 'SSH workspace'},
          ],
        }),
      ]),
      _sseForText('Using local.'),
    ]);
    await _mountAgent(tester, http, _MemoryFileSystemAdapter());
    await _sendTask(tester, 'Choose a target');
    await tester.ensureVisible(find.text('Use local'));
    await tester.tap(find.text('Use local'));
    await _drainAgent(tester);
    expect(_lastToolResult(http)['tool_call_id'], 'question');
    expect(_lastToolResult(http)['content'], contains('Use local'));
    expect(http.requestBodies, hasLength(2));
  });

  for (final width in [320.0, 540.0]) {
    testWidgets('command badges sit above full-width text at $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final completion = Completer<CommandResult>();
      HttpOverrides.global = _QueuedHttpOverrides([
        _sseForToolCalls([
          _nativeCall('layout', 'bash', {
            'command':
                'printf "a command long enough to wrap in a narrow panel"',
            'reason': 'Check command card layout',
            'risk_level': 'normal',
            'risk_reason': 'Read only',
          }),
        ]),
        _sseForText('Done.'),
      ]);
      addTearDown(() => HttpOverrides.global = null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiAssistantOverlay(
              visible: true,
              initialPosition: AiPanelPosition.right,
              initialSize: width,
              agentConfig: _fakeAgentConfig(),
              onExecuteAsync: (cmd, {isCancelled, onUpdate, onSilence}) =>
                  completion.future,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await _sendTask(tester, 'Check layout');

      void expectHeaderAboveCommand(String status) {
        final risk = tester.getRect(find.text('普通'));
        final state = tester.getRect(find.text(status));
        final command = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                (widget.data?.startsWith(r'$ printf') ?? false),
          ),
        );
        final purpose = tester.getRect(
          find.text('执行目的：Check command card layout'),
        );
        expect(risk.center.dy, closeTo(state.center.dy, 1));
        expect(command.top, greaterThanOrEqualTo(risk.bottom));
        expect(command.top, greaterThanOrEqualTo(state.bottom));
        expect(command.left, closeTo(risk.left - 6, 1));
        expect(command.width, closeTo(purpose.width, 1));
        expect(command.right, greaterThan(state.right));
        expect(tester.takeException(), isNull);
      }

      expectHeaderAboveCommand('运行中');
      completion.complete(
        CommandResult(output: 'layout verified', exitCode: 0),
      );
      await _drainAgent(tester);
      expectHeaderAboveCommand('exit 0');
    });
  }

  testWidgets('mixed shell and file search both execute in one tool turn', (
    tester,
  ) async {
    const path = '/fixture/sample.txt';
    HttpOverrides.global = _QueuedHttpOverrides([
      _sseForToolCalls([
        {
          'index': 0,
          'id': 'call_shell',
          'function': {
            'name': 'bash',
            'arguments': jsonEncode({
              'command': 'pwd',
              'reason': 'Check directory',
              'risk_level': 'normal',
              'risk_reason': 'Read only',
            }),
          },
        },
        {
          'index': 1,
          'id': 'call_search',
          'function': {
            'name': 'grep_file',
            'arguments': jsonEncode({'path': path, 'pattern': 'target'}),
          },
        },
      ]),
      _sseForText('Found the target marker. [TASK_COMPLETE]'),
    ]);
    addTearDown(() => HttpOverrides.global = null);
    final executed = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAssistantOverlay(
            visible: true,
            initialPosition: AiPanelPosition.bottom,
            agentConfig: _fakeAgentConfig(),
            fileSystemAdapter: _MemoryFileSystemAdapter(),
            onExecuteAsync: (cmd, {isCancelled, onUpdate, onSilence}) async {
              executed.add(cmd);
              return CommandResult(output: '', exitCode: 0);
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Find the marker');
    await tester.tap(find.byIcon(Icons.send_rounded));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();

    expect(executed, ['pwd']);
    expect(find.textContaining('1: target marker'), findsOneWidget);
    expect(find.textContaining('Found the target marker'), findsOneWidget);
  });

  testWidgets(
    'raw web-search envelopes are retried instead of shown as answers',
    (tester) async {
      final rawSearch = '''Here are the results you requested:

```text
[Web search results]
query: "Beijing current weather"
(2 results)

1. Beijing weather
   Current conditions.
```''';
      HttpOverrides.global = _QueuedHttpOverrides([
        _sseForText(rawSearch),
        _sseForText('北京当前多云，约 26°C。\n[TASK_COMPLETE]'),
      ]);
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

      await tester.enterText(find.byType(TextField), '北京天气如何');
      await tester.tap(find.byIcon(Icons.send_rounded));
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pumpAndSettle();

      expect(find.textContaining('北京当前多云'), findsOneWidget);
      expect(find.textContaining('[Web search results]'), findsNothing);
    },
  );

  testWidgets('streamed agent replies keep the transcript pinned to the bottom', (
    tester,
  ) async {
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
  });
}

Map<String, Object?> _nativeCall(
  String id,
  String name,
  Map<String, Object?> arguments, {
  int index = 0,
}) => {
  'index': index,
  'id': id,
  'function': {'name': name, 'arguments': jsonEncode(arguments)},
};

Future<void> _mountAgent(
  WidgetTester tester,
  _QueuedHttpOverrides http,
  _MemoryFileSystemAdapter files, {
  List<String>? executed,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  HttpOverrides.global = http;
  addTearDown(() => HttpOverrides.global = null);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AiAssistantOverlay(
          visible: true,
          initialPosition: AiPanelPosition.bottom,
          initialSize: 540,
          agentConfig: _fakeAgentConfig().copyWith(fileWriteEnabled: true),
          fileSystemAdapter: files,
          onExecuteAsync: (cmd, {isCancelled, onUpdate, onSilence}) async {
            executed?.add(cmd);
            return CommandResult(output: '', exitCode: 0);
          },
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

Future<void> _sendTask(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byIcon(Icons.send_rounded));
  await _drainAgent(tester);
}

Future<void> _drainAgent(WidgetTester tester) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Map<String, dynamic> _lastToolResult(_QueuedHttpOverrides http) {
  final body = jsonDecode(http.requestBodies.last) as Map;
  return Map<String, dynamic>.from(
    (body['messages'] as List).lastWhere((m) => m['role'] == 'tool') as Map,
  );
}

List<String> _sseForText(String text) => [
  'data: ${jsonEncode({
    'choices': [
      {
        'delta': {'content': text},
      },
    ],
  })}',
  'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
  'data: [DONE]',
];

List<String> _sseForToolCalls(List<Map<String, Object?>> calls) => [
  'data: ${jsonEncode({
    'choices': [
      {
        'delta': {'tool_calls': calls},
        'finish_reason': 'tool_calls',
      },
    ],
  })}',
  'data: [DONE]',
];

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

class _QueuedHttpOverrides extends HttpOverrides {
  _QueuedHttpOverrides(this.responses);
  final List<List<String>> responses;
  final List<String> requestBodies = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _QueuedHttpClient(responses, requestBodies);
}

class _QueuedHttpClient implements HttpClient {
  _QueuedHttpClient(this.responses, this.requestBodies);
  final List<List<String>> responses;
  final List<String> requestBodies;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _QueuedRequest(responses, requestBodies);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClient.${invocation.memberName}');
}

class _QueuedRequest implements HttpClientRequest {
  _QueuedRequest(this.responses, this.requestBodies);
  final List<List<String>> responses;
  final List<String> requestBodies;
  final bytes = <int>[];

  @override
  HttpHeaders get headers => _MockHeaders();

  @override
  void add(List<int> data) => bytes.addAll(data);

  @override
  Future<HttpClientResponse> close() async {
    requestBodies.add(utf8.decode(bytes));
    return _MockResponse(_sseStream(responses.removeAt(0)));
  }

  Stream<List<int>> _sseStream(List<String> events) async* {
    for (final event in events) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield utf8.encode('$event\n\n');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClientRequest.${invocation.memberName}');
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

class _MemoryFileSystemAdapter implements FileSystemAdapter {
  String? writtenContent;
  final writtenContents = <String>[];
  Future<void>? previewWaiter;

  @override
  String get label => 'fixture';

  @override
  bool get isAvailable => true;

  @override
  String? get currentDirectory => '/fixture';

  @override
  Future<FileWritePreview> preview(String path) async {
    await previewWaiter;
    return FileWritePreview(resolvedPath: path, exists: false, existingSize: 0);
  }

  @override
  Future<String> readContent(String path) async => 'target marker\n';

  @override
  Future<FileWriteResult> commit(
    String path,
    String content, {
    DateTime? expectedMtime,
  }) async {
    writtenContent = content;
    writtenContents.add(content);
    return FileWriteResult(
      resolvedPath: path,
      bytesWritten: utf8.encode(content).length,
      created: true,
    );
  }

  @override
  Future<AgentFileChunk> readRange(
    String path, {
    required int offset,
    required int maxBytes,
  }) async {
    final bytes = utf8.encode('target marker\n');
    final end = (offset + maxBytes).clamp(0, bytes.length);
    return AgentFileChunk(
      bytes: Uint8List.fromList(bytes.sublist(offset, end)),
      totalBytes: bytes.length,
      offset: offset,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FileSystemAdapter.${invocation.memberName}');
}
