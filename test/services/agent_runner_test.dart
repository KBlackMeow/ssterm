import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/agent_context_budget.dart';
import 'package:ssterm/services/agent_execution_budget.dart';
import 'package:ssterm/services/agent_model.dart';
import 'package:ssterm/services/agent_runner.dart';
import 'package:ssterm/services/agent_tool_contract.dart';
import 'package:ssterm/services/agent_tool_registry.dart';
import 'package:ssterm/services/llm_service.dart';

AgentToolCall _call(String id, String name, Map<String, Object?> arguments) =>
    AgentToolCall.fromRaw(id: id, name: name, arguments: arguments)!;

AgentToolCall _shell(String id) => _call(id, 'bash', {
  'command': 'pwd',
  'reason': 'Inspect directory',
  'risk_level': 'normal',
  'risk_reason': 'Read only',
});

List<LlmStreamEvent> _tools(List<AgentToolCall> calls) => [
  for (final call in calls) LlmStreamEvent('tool_call', '', toolCall: call),
];

class _Model implements AgentModel {
  _Model(this.responses);
  final List<Stream<LlmStreamEvent> Function()> responses;
  final requests = <List<AgentConversationItem>>[];
  int closes = 0;
  int resets = 0;
  String? summary;
  int summaries = 0;
  Future<String?> Function(String)? summarizeWith;

  @override
  Stream<LlmStreamEvent> stream(List<AgentConversationItem> messages) {
    requests.add(List.of(messages));
    return responses.removeAt(0)();
  }

  @override
  Future<String?> summarize(String prompt) async {
    summaries++;
    return summarizeWith == null ? summary : summarizeWith!(prompt);
  }

  @override
  void reset() => resets++;
  @override
  void close() => closes++;
}

_Model _script(List<List<LlmStreamEvent>> turns) =>
    _Model([for (final turn in turns) () => Stream.fromIterable(turn)]);

List<LlmStreamEvent> _done() => [
  LlmStreamEvent('text', 'Done. [TASK_COMPLETE]'),
];

AgentRunner _runner(
  _Model model, {
  AgentToolExecutor? execute,
  Map<String, String> skills = const {},
  Future<String?> Function(String)? loadSkill,
  AgentExecutionBudget? budget,
  Future<void> Function(Duration)? delay,
}) => AgentRunner(
  history: AgentConversationHistory()
    ..add(
      AgentConversationItem.text(
        role: 'user',
        content: 'Inspect the workspace',
      ),
    ),
  model: model,
  contextBudget: AgentContextBudget.forContextWindow(128000),
  registry: () => AgentToolRegistry.build(
    skillsEnabled: true,
    fileWriteEnabled: true,
    webSearchEnabled: true,
  ),
  executeTool:
      execute ??
      (call, _) async => AgentToolExecution.completed(
        AgentToolResult(toolCallId: call.id, content: '/workspace'),
      ),
  skills: skills,
  loadSkill: loadSkill,
  budget: budget,
  delay: delay,
);

void main() {
  test(
    'runs without a widget and exposes immutable streaming snapshots',
    () async {
      final model = _script([
        [LlmStreamEvent('text', 'Hello '), LlmStreamEvent('text', 'world')],
      ]);
      final runner = _runner(model);
      final events = <AgentRunnerEvent>[];
      runner.subscribe(events.add);
      await runner.run();
      expect(runner.state, AgentRunState.completed);
      expect(runner.history.last.content, 'Hello world');
      expect(
        events.whereType<AgentResponseUpdated>().first.reply.text,
        'Hello ',
      );
      expect(
        events.whereType<AgentResponseCompleted>().single.displayText,
        'Hello world',
      );
      expect(events.last, isA<AgentRunEnded>());
      expect(model.requests, hasLength(1));
      expect(model.closes, greaterThan(0));
    },
  );

  test(
    'loads a skill before the next model request and executes its tool turn',
    () async {
      final model = _script([
        _tools([
          _call('skill', 'use_skill', {'skill_id': 'inspect'}),
        ]),
        _tools([_shell('shell')]),
        _done(),
      ]);
      final order = <String>[];
      final runner = _runner(
        model,
        skills: {'inspect': 'Inspect workspace'},
        loadSkill: (id) async {
          order.add('load:$id');
          return 'Run pwd to inspect the workspace.';
        },
        execute: (call, _) async {
          order.add('execute:${call.id}');
          expect(
            model.requests[1].last.toolResults.single.content,
            contains('Run pwd'),
          );
          return AgentToolExecution.completed(
            AgentToolResult(toolCallId: call.id, content: '/workspace'),
          );
        },
      );
      await runner.run();
      expect(order, ['load:inspect', 'execute:shell']);
      expect(model.requests[2].last.toolResults.single.toolCallId, 'shell');
      expect(runner.state, AgentRunState.completed);
    },
  );

  test(
    'unavailable skill never invokes its loader and returns paired error',
    () async {
      final model = _script([
        _tools([
          _call('skill', 'use_skill', {'skill_id': 'disabled'}),
        ]),
        _done(),
      ]);
      final runner = _runner(
        model,
        loadSkill: (_) => throw StateError('must not load'),
      );
      await runner.run();
      final result = model.requests.last.last.toolResults.single;
      expect(result.toolCallId, 'skill');
      expect(result.isError, isTrue);
      expect(result.content, contains('DO NOT retry'));
    },
  );

  test('rejects the entire malformed batch before any tool executes', () async {
    final model = _script([
      _tools([
        _shell('ok'),
        _call('bad', 'bash', {'command': 'pwd'}),
      ]),
      _done(),
    ]);
    final runner = _runner(
      model,
      execute: (_, _) => throw StateError('must not execute'),
    );
    await runner.run();
    final results = model.requests.last.last.toolResults;
    expect(results.map((r) => r.toolCallId), ['ok', 'bad']);
    expect(results.every((r) => r.isError), isTrue);
  });

  test(
    'skill and dependent action cannot be executed in the same batch',
    () async {
      final model = _script([
        _tools([
          _call('skill', 'use_skill', {'skill_id': 'inspect'}),
          _shell('shell'),
        ]),
        _done(),
      ]);
      final runner = _runner(
        model,
        execute: (_, _) => throw StateError('must not execute'),
        skills: {'inspect': 'inspect'},
        loadSkill: (_) => throw StateError('must not load'),
      );
      await runner.run();
      expect(
        model.requests.last.last.toolResults.every((r) => r.isError),
        isTrue,
      );
    },
  );

  for (final tool in ['write_file', 'edit_file']) {
    for (final approved in [true, false]) {
      test(
        '$tool pauses and resumes its original call after ${approved ? 'approval' : 'rejection'}',
        () async {
          final call = _call(
            'file',
            tool,
            tool == 'write_file'
                ? {'path': '/workspace/a', 'content': 'new'}
                : {
                    'path': '/workspace/a',
                    'old_string': 'old',
                    'new_string': 'new',
                  },
          );
          final model = _script([
            _tools([call]),
            _done(),
          ]);
          final runner = _runner(
            model,
            execute: (_, _) async => const AgentToolExecution.paused(),
          );
          await runner.run();
          expect(runner.state, AgentRunState.paused);
          expect(runner.pendingTool?.id, 'file');
          expect(model.closes, 0);
          expect(model.requests, hasLength(1));
          expect(runner.history.last.toolCalls.single.id, 'file');
          expect(
            () => runner.resume(
              const AgentToolResult(toolCallId: 'wrong', content: 'x'),
            ),
            throwsStateError,
          );
          await runner.resume(
            AgentToolResult(
              toolCallId: 'file',
              content: approved ? 'applied' : 'rejected',
              isError: !approved,
            ),
            stop: !approved,
          );
          final result = runner.history
              .firstWhere((item) => item.toolResults.isNotEmpty)
              .toolResults
              .single;
          expect(result.toolCallId, 'file');
          expect(result.isError, !approved);
          expect(runner.iteration, approved ? 2 : 1);
          expect(
            runner.state,
            approved ? AgentRunState.completed : AgentRunState.stopped,
          );
          expect(() => runner.resume(result), throwsStateError);
        },
      );
    }
  }

  test('mixed tools execute serially in exactly the model order', () async {
    final calls = [
      _call('read', 'read_file', {'path': '/a', 'offset': 0}),
      _call('search', 'web_search', {'query': 'topic'}),
      _shell('shell'),
      _call('write', 'write_file', {'path': '/a', 'content': 'new'}),
    ];
    final model = _script([_tools(calls), _done()]);
    final order = <String>[];
    var active = 0;
    final runner = _runner(
      model,
      execute: (call, _) async {
        active++;
        expect(active, 1, reason: 'No calls may overlap');
        order.add('${call.id}:start');
        await Future<void>.delayed(Duration.zero);
        order.add('${call.id}:end');
        active--;
        return AgentToolExecution.completed(
          AgentToolResult(toolCallId: call.id, content: call.id),
        );
      },
    );
    await runner.run();
    expect(order, [
      'read:start',
      'read:end',
      'search:start',
      'search:end',
      'shell:start',
      'shell:end',
      'write:start',
      'write:end',
    ]);
    expect(model.requests, hasLength(2));
    expect(model.requests.last.last.toolResults.map((r) => r.toolCallId), [
      'read',
      'search',
      'shell',
      'write',
    ]);
    expect(runner.state, AgentRunState.completed);
  });

  test(
    'multiple approval pauses retain the cursor and earlier results',
    () async {
      final model = _script([
        _tools([
          _call('read', 'read_file', {'path': '/a', 'offset': 0}),
          _call('write', 'write_file', {'path': '/a', 'content': 'new'}),
          _call('edit', 'edit_file', {
            'path': '/b',
            'old_string': 'old',
            'new_string': 'new',
          }),
          _shell('shell'),
        ]),
        _done(),
      ]);
      final order = <String>[];
      final runner = _runner(
        model,
        execute: (call, _) async {
          order.add(call.id);
          if (call.id == 'write' || call.id == 'edit') {
            return const AgentToolExecution.paused();
          }
          return AgentToolExecution.completed(
            AgentToolResult(toolCallId: call.id, content: '${call.id} output'),
          );
        },
      );
      await runner.run();
      expect(order, ['read', 'write']);
      expect(runner.pendingTool?.id, 'write');
      expect(model.requests, hasLength(1));
      await runner.resume(
        const AgentToolResult(toolCallId: 'write', content: 'written'),
      );
      expect(order, ['read', 'write', 'edit']);
      expect(runner.pendingTool?.id, 'edit');
      expect(model.requests, hasLength(1));
      expect(runner.iteration, 1);
      expect(model.closes, 0);
      await runner.resume(
        const AgentToolResult(toolCallId: 'edit', content: 'edited'),
      );
      expect(order, ['read', 'write', 'edit', 'shell']);
      expect(model.requests, hasLength(2));
      expect(model.requests.last.last.toolResults.map((r) => r.content), [
        'read output',
        'written',
        'edited',
        'shell output',
      ]);
      expect(runner.state, AgentRunState.completed);
    },
  );

  for (final reject in [true, false]) {
    test(
      '${reject ? 'rejecting' : 'cancelling'} a paused mixed batch skips remaining tools',
      () async {
        final model = _script([
          _tools([
            _call('read', 'read_file', {'path': '/a', 'offset': 0}),
            _call('write', 'write_file', {'path': '/a', 'content': 'new'}),
            _shell('later'),
          ]),
        ]);
        final order = <String>[];
        final runner = _runner(
          model,
          execute: (call, _) async {
            order.add(call.id);
            return call.id == 'write'
                ? const AgentToolExecution.paused()
                : AgentToolExecution.completed(
                    AgentToolResult(
                      toolCallId: call.id,
                      content: 'earlier output',
                    ),
                  );
          },
        );
        await runner.run();
        if (reject) {
          await runner.resume(
            const AgentToolResult(
              toolCallId: 'write',
              content: 'rejected',
              isError: true,
            ),
            stop: true,
          );
        } else {
          runner.cancel();
        }
        expect(order, ['read', 'write']);
        expect(model.requests, hasLength(1));
        expect(
          runner.state,
          reject ? AgentRunState.stopped : AgentRunState.cancelled,
        );
        final results = runner.history.last.toolResults;
        expect(results.map((r) => r.toolCallId), ['read', 'write', 'later']);
        expect(results.first.content, 'earlier output');
        expect(results.skip(1).every((r) => r.isError), isTrue);
      },
    );
  }

  test(
    'question answers resume the ordered batch before another model request',
    () async {
      final answer = Completer<AgentToolExecution>();
      final asked = Completer<void>();
      final model = _script([
        _tools([
          _call('question', 'ask_user_question', {
            'question': 'Which target?',
            'header': 'Target',
            'options': [
              {'label': 'Local', 'description': 'local'},
              {'label': 'Remote', 'description': 'remote'},
            ],
          }),
          _shell('shell'),
        ]),
        _done(),
      ]);
      final order = <String>[];
      final runner = _runner(
        model,
        execute: (call, _) async {
          order.add(call.id);
          if (call.id == 'question') {
            asked.complete();
            return answer.future;
          }
          return AgentToolExecution.completed(
            AgentToolResult(toolCallId: call.id, content: 'shell output'),
          );
        },
      );
      final run = runner.run();
      await asked.future;
      expect(order, ['question']);
      expect(model.requests, hasLength(1));
      answer.complete(
        const AgentToolExecution.completed(
          AgentToolResult(toolCallId: 'question', content: 'Local'),
        ),
      );
      await run;
      expect(order, ['question', 'shell']);
      expect(model.requests.last.last.toolResults.map((r) => r.toolCallId), [
        'question',
        'shell',
      ]);
    },
  );

  test('approval resumes with the same execution budget', () async {
    final model = _script([
      _tools([
        _call('write', 'write_file', {'path': '/a', 'content': 'a'}),
      ]),
    ]);
    final runner = _runner(
      model,
      budget: AgentExecutionBudget(maxModelRequests: 1),
      execute: (_, _) async => const AgentToolExecution.paused(),
    );
    await runner.run();
    await runner.resume(
      const AgentToolResult(toolCallId: 'write', content: 'applied'),
    );
    expect(model.requests, hasLength(1));
    expect(runner.state, AgentRunState.stopped);
    expect(
      runner.history.last.content,
      contains('model request limit reached'),
    );
  });

  test(
    'command rejection terminates task and answers remaining calls',
    () async {
      final model = _script([
        _tools([_shell('first'), _shell('second'), _shell('third')]),
      ]);
      final executed = <String>[];
      final runner = _runner(
        model,
        execute: (call, _) async {
          executed.add(call.id);
          return call.id == 'second'
              ? const AgentToolExecution.stopped()
              : AgentToolExecution.completed(
                  AgentToolResult(toolCallId: call.id, content: 'first output'),
                );
        },
      );
      await runner.run();
      expect(executed, ['first', 'second']);
      expect(model.requests, hasLength(1));
      expect(runner.state, AgentRunState.stopped);
      final results = runner.history.last.toolResults;
      expect(results.map((r) => r.toolCallId), ['first', 'second', 'third']);
      expect(results.first.content, 'first output');
      expect(results.skip(1).every((r) => r.isError), isTrue);
    },
  );

  test(
    'cancels in-flight tool without awaiting it or recording late output',
    () async {
      final pending = Completer<AgentToolExecution>();
      final started = Completer<void>();
      final model = _script([
        _tools([_shell('first'), _shell('second')]),
      ]);
      final runner = _runner(
        model,
        execute: (_, _) {
          started.complete();
          return pending.future;
        },
      );
      final run = runner.run();
      await started.future;
      runner.cancel();
      await run;
      expect(runner.state, AgentRunState.cancelled);
      final before = List.of(runner.history);
      pending.complete(
        const AgentToolExecution.completed(
          AgentToolResult(toolCallId: 'first', content: 'late'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(runner.history, before);
      expect(runner.history.last.toolResults, hasLength(2));
      expect(runner.history.last.toolResults.every((r) => r.isError), isTrue);
      expect(model.requests, hasLength(1));
    },
  );

  test(
    'cancels while skill loads and never starts a dependent model turn',
    () async {
      final body = Completer<String?>();
      final started = Completer<void>();
      final model = _script([
        _tools([
          _call('skill', 'use_skill', {'skill_id': 'inspect'}),
        ]),
      ]);
      final runner = _runner(
        model,
        skills: {'inspect': 'Inspect'},
        loadSkill: (_) {
          started.complete();
          return body.future;
        },
      );
      final events = <AgentRunnerEvent>[];
      runner.subscribe(events.add);
      final run = runner.run();
      await started.future;
      runner.cancel();
      await run;
      body.complete('Late instructions');
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AgentSkillLoaded>(), isEmpty);
      expect(model.requests, hasLength(1));
      expect(runner.history.last.toolResults.single.isError, isTrue);
    },
  );

  test(
    'cancellation while paused prevents later approval and pairs interruption',
    () async {
      final model = _script([
        _tools([
          _call('write', 'write_file', {'path': '/a', 'content': 'a'}),
        ]),
      ]);
      final runner = _runner(
        model,
        execute: (_, _) async => const AgentToolExecution.paused(),
      );
      await runner.run();
      runner.cancel();
      expect(runner.history.last.toolResults.single.toolCallId, 'write');
      expect(runner.history.last.toolResults.single.isError, isTrue);
      expect(
        () => runner.resume(
          const AgentToolResult(toolCallId: 'write', content: 'late'),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'can stop from tool-start event before starting a side effect',
    () async {
      final model = _script([
        _tools([_shell('shell')]),
      ]);
      final runner = _runner(
        model,
        execute: (_, _) => throw StateError('must not execute'),
      );
      runner.subscribe((event) {
        if (event is AgentToolStarted) runner.cancel();
      });
      await runner.run();
      expect(runner.state, AgentRunState.cancelled);
      expect(runner.history.last.toolResults.single.isError, isTrue);
    },
  );

  test('tool exception is returned to model as a paired error', () async {
    final model = _script([
      _tools([_shell('shell')]),
      _done(),
    ]);
    final runner = _runner(
      model,
      execute: (_, _) async => throw const FileSystemException('unavailable'),
    );
    await runner.run();
    expect(runner.state, AgentRunState.completed);
    expect(model.requests.last.last.toolResults.single.isError, isTrue);
    expect(
      model.requests.last.last.toolResults.single.content,
      contains('unavailable'),
    );
  });

  test(
    'retries a transient failure before output and reuses model transport',
    () async {
      final model = _Model([
        () => Stream.error(const HttpException('Connection closed')),
        () => Stream.fromIterable(_done()),
      ]);
      final delays = <Duration>[];
      final runner = _runner(
        model,
        delay: (duration) async {
          delays.add(duration);
        },
      );
      await runner.run();
      expect(runner.state, AgentRunState.completed);
      expect(model.requests, hasLength(2));
      expect(model.resets, 1);
      expect(delays, [const Duration(milliseconds: 500)]);
    },
  );

  for (final kind in ['text', 'reasoning', 'tool_call']) {
    test('never retries after partial $kind output', () async {
      final model = _Model([
        () async* {
          yield LlmStreamEvent(
            kind,
            kind == 'tool_call' ? '' : 'partial',
            toolCall: kind == 'tool_call' ? _shell('shell') : null,
          );
          throw const HttpException('Connection closed');
        },
      ]);
      final runner = _runner(model);
      await runner.run();
      expect(runner.state, AgentRunState.failed);
      expect(model.requests, hasLength(1));
      expect(model.resets, 0);
    });
  }

  test('cancellation interrupts retry backoff immediately', () async {
    final waiting = Completer<void>();
    final started = Completer<void>();
    final model = _Model([
      () => Stream.error(const LlmHttpException(429, 'limited')),
    ]);
    final runner = _runner(
      model,
      delay: (_) {
        started.complete();
        return waiting.future;
      },
    );
    final run = runner.run();
    await started.future;
    runner.cancel();
    await run;
    expect(runner.state, AgentRunState.cancelled);
    expect(model.requests, hasLength(1));
    waiting.complete();
  });

  test(
    'cancellation does not wait for a non-cooperative model stream',
    () async {
      final stream = StreamController<LlmStreamEvent>();
      final started = Completer<void>();
      final model = _Model([
        () {
          started.complete();
          return stream.stream;
        },
      ]);
      final runner = _runner(model);
      final run = runner.run();
      await started.future;
      runner.cancel();
      await run;
      expect(runner.state, AgentRunState.cancelled);
      stream.add(LlmStreamEvent('text', 'late output'));
      await stream.close();
      expect(runner.history, hasLength(1));
    },
  );

  test('context overflow forces compaction once before retrying', () async {
    final model = _Model([
      () =>
          Stream.error(const LlmHttpException(400, 'context_length exceeded')),
      () => Stream.fromIterable(_done()),
    ])..summary = 'Workspace inspection in progress.';
    final runner = _runner(model);
    for (var i = 0; i < 40; i++) {
      runner.history.add(
        AgentConversationItem.text(
          role: 'assistant',
          content: 'old evidence $i ${'evidence ' * 150}',
        ),
      );
    }
    await runner.run();
    expect(runner.state, AgentRunState.completed);
    expect(model.summaries, 1);
    expect(model.resets, 1);
    expect(model.requests, hasLength(2));
    expect(runner.history.first.content, 'Inspect the workspace');
    expect(runner.history.summaryContent, contains('inspection in progress'));
  });

  test(
    'a second context overflow ends the task instead of retrying forever',
    () async {
      final model = _Model([
        () => Stream.error(
          const LlmHttpException(400, 'context_length exceeded'),
        ),
        () => Stream.error(
          const LlmHttpException(400, 'context_length exceeded'),
        ),
      ]);
      final runner = _runner(model);
      await runner.run();
      expect(runner.state, AgentRunState.failed);
      expect(model.requests, hasLength(2));
      expect(model.resets, 1);
    },
  );

  test(
    'cancelling compaction prevents late summary from changing history',
    () async {
      final pending = Completer<String?>();
      final started = Completer<void>();
      final model = _Model([])
        ..summarizeWith = (_) {
          started.complete();
          return pending.future;
        };
      final runner = _runner(model);
      for (var i = 0; i < 90; i++) {
        runner.history.add(
          AgentConversationItem.text(
            role: 'assistant',
            content: 'old evidence $i ${'evidence ' * 150}',
          ),
        );
      }
      final before = List.of(runner.history);
      final run = runner.run();
      await started.future;
      runner.cancel();
      await run;
      pending.complete('Late summary');
      await Future<void>.delayed(Duration.zero);
      expect(runner.history, before);
      expect(model.requests, isEmpty);
    },
  );

  test(
    'cancellation on resumed tool event cannot restart a cancelled task',
    () async {
      final model = _script([
        _tools([
          _call('write', 'write_file', {'path': '/a', 'content': 'a'}),
        ]),
      ]);
      final runner = _runner(
        model,
        execute: (_, _) async => const AgentToolExecution.paused(),
      );
      await runner.run();
      runner.subscribe((event) {
        if (event is AgentToolCompleted) runner.cancel();
      });
      await runner.resume(
        const AgentToolResult(toolCallId: 'write', content: 'applied'),
      );
      expect(runner.state, AgentRunState.cancelled);
      expect(model.requests, hasLength(1));
      expect(model.closes, 1);
    },
  );

  test(
    'cancelling from a terminal tool result keeps the cancelled state',
    () async {
      final model = _script([
        _tools([_shell('shell')]),
      ]);
      final runner = _runner(
        model,
        execute: (call, _) async => AgentToolExecution.stopped(
          AgentToolResult(
            toolCallId: call.id,
            content: 'No executor',
            isError: true,
          ),
        ),
      );
      runner.subscribe((event) {
        if (event is AgentToolCompleted) runner.cancel();
      });
      await runner.run();
      expect(runner.state, AgentRunState.cancelled);
      expect(runner.history.last.toolResults.single.content, 'No executor');
    },
  );

  test(
    'cancellation at compaction start does not launch a summary request',
    () async {
      final model = _Model([]);
      final runner = _runner(model);
      for (var i = 0; i < 90; i++) {
        runner.history.add(
          AgentConversationItem.text(
            role: 'assistant',
            content: 'evidence ' * 150,
          ),
        );
      }
      runner.subscribe((event) {
        if (event is AgentStatusChanged &&
            event.text == 'Compressing context…') {
          runner.cancel();
        }
      });
      await runner.run();
      expect(runner.state, AgentRunState.cancelled);
      expect(model.summaries, 0);
      expect(model.requests, isEmpty);
    },
  );

  test(
    'keeps provider-specific tool metadata in the next model turn',
    () async {
      final call = AgentToolCall.fromRaw(
        id: 'm',
        name: 'bash',
        arguments: _shell('m').arguments,
        thoughtSignature: 'opaque-signature',
      )!;
      final model = _script([
        _tools([call]),
        _done(),
      ]);
      final runner = _runner(model);
      await runner.run();
      expect(
        model.requests.last[1].toolCalls.single.thoughtSignature,
        'opaque-signature',
      );
    },
  );
}
