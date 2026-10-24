import 'dart:async';
import 'dart:io';

import 'agent_context_budget.dart';
import 'agent_conversation_manager.dart';
import 'agent_execution_budget.dart';
import 'agent_model.dart';
import 'agent_stream_client_session.dart';
import 'agent_tool_batch.dart';
import 'agent_tool_contract.dart';
import 'agent_tool_registry.dart';
import 'llm_service.dart';

part 'agent_runner_events.dart';

/// A host tool may finish, pause for a later decision, or stop the task.
/// Only the runner appends model messages and pairs tool results.
class AgentToolExecution {
  const AgentToolExecution.completed(AgentToolResult this.result)
    : paused = false,
      stop = false;
  const AgentToolExecution.paused()
    : result = null,
      paused = true,
      stop = false;
  const AgentToolExecution.stopped([this.result]) : paused = false, stop = true;

  final AgentToolResult? result;
  final bool paused;
  final bool stop;
}

enum AgentRunState {
  idle,
  running,
  paused,
  completed,
  cancelled,
  stopped,
  failed,
}

typedef AgentToolExecutor =
    Future<AgentToolExecution> Function(AgentToolCall call, AgentRunner runner);

/// Owns a user task, independent of rendering: model turns, validation,
/// compaction, skill loading, tool-result pairing, pause/resume and cancellation.
/// A runner is single-use; a paused task resumes on the same instance.
class AgentRunner {
  AgentRunner({
    required this.history,
    required this.model,
    required this.registry,
    required this.executeTool,
    required this.contextBudget,
    this.skills = const {},
    this.loadSkill,
    AgentExecutionBudget? budget,
    this.lastPromptTokenCount,
    Future<void> Function(Duration)? delay,
    this.log,
  }) : budget = budget ?? AgentExecutionBudget(),
       _delay = delay ?? Future<void>.delayed;

  final AgentConversationHistory history;
  final AgentModel model;
  final AgentToolRegistry Function() registry;
  final AgentToolExecutor executeTool;
  final AgentContextBudget contextBudget;
  final Map<String, String> skills;
  final Future<String?> Function(String id)? loadSkill;
  final AgentExecutionBudget budget;
  final Future<void> Function(Duration) _delay;
  final void Function(String message)? log;
  final _listeners = <void Function(AgentRunnerEvent)>{};
  final _cancelled = Completer<void>();
  AgentRunState _state = AgentRunState.idle;
  int? lastPromptTokenCount;
  int iteration = 0;
  List<AgentToolCall> _calls = const [];
  final _results = <AgentToolResult>[];
  AgentToolCall? _pending;
  int _nextCallIndex = 0;
  bool _modelClosed = false;

  AgentRunState get state => _state;
  bool get isCancelled => _state == AgentRunState.cancelled;
  AgentToolCall? get pendingTool => _pending;

  void Function() subscribe(void Function(AgentRunnerEvent) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _emit(AgentRunnerEvent event) {
    for (final listener in List.of(_listeners)) {
      listener(event);
    }
  }

  Future<void> run() {
    if (_state != AgentRunState.idle) throw StateError('Task already started.');
    return _drive();
  }

  /// A rejection stops the task; an approved or failed operation may resume
  /// the remaining independent calls without another model request.
  Future<void> resume(AgentToolResult result, {bool stop = false}) {
    if (_state != AgentRunState.paused || result.toolCallId != _pending?.id) {
      throw StateError('Result must answer the paused tool call.');
    }
    _results.add(result);
    _pending = null;
    return _drive(resumed: result, stopAfterResume: stop);
  }

  /// Invalidates pending work immediately, including a non-cooperative tool or
  /// summary request. Late results can never modify this task's transcript.
  void cancel() {
    if (_state != AgentRunState.idle &&
        _state != AgentRunState.running &&
        _state != AgentRunState.paused) {
      return;
    }
    final wasPaused = _state == AgentRunState.paused;
    _state = AgentRunState.cancelled;
    _pending = null;
    _flushResults(missingReason: 'interrupted by user');
    _cancelled.complete();
    _closeModel();
    if (wasPaused) _emit(AgentRunEnded(_state));
  }

  Future<T> _active<T>(Future<T> operation) => Future.any([
    operation,
    _cancelled.future.then<T>((_) => throw const _RunCancelled()),
  ]);

  Future<void> _drive({
    AgentToolResult? resumed,
    bool stopAfterResume = false,
  }) async {
    _state = AgentRunState.running;
    _emit(const AgentRunStarted());
    try {
      if (resumed != null && !isCancelled) {
        _emit(AgentToolCompleted(resumed));
        if (!isCancelled && stopAfterResume) {
          _state = AgentRunState.stopped;
          _flushResults(missingReason: 'user rejected the pending operation');
        } else if (!isCancelled) {
          await _executeBatch();
        }
      }
      while (_state == AgentRunState.running) {
        iteration++;
        await _compact();
        if (isCancelled) break;
        if (contextBudget.isHardLimitExceeded(
          estimatedTokens: AgentContextBudget.estimateHistoryTokens(history),
          exactUsageTokens: lastPromptTokenCount,
        )) {
          _stop(
            '[Agent run stopped] Context remains above the safe model limit after compaction.',
          );
          break;
        }
        final stop = budget.consumeModelRequest(DateTime.now());
        if (stop != null) {
          _stopForBudget(stop);
          break;
        }
        _emit(const AgentResponseStarted());
        if (isCancelled) break;
        final reply = await _readResponse();
        if (isCancelled) break;
        lastPromptTokenCount = reply.promptTokenCount;
        final text = LlmService.stripForgedCommandFeedback(reply.text);
        final error = LlmService.incompleteStreamError(
          text: text,
          hasReasoning: reply.reasoning.isNotEmpty,
          toolCallCount: reply.toolCalls.length,
          finishReason: reply.finishReason,
          malformedEventCount: reply.malformedEventCount,
        );
        if (error != null) throw StateError(error);
        if (reply.toolCalls.isEmpty &&
            LlmService.isRawWebSearchEnvelope(text)) {
          history.add(
            AgentConversationItem.text(role: 'assistant', content: text),
          );
          history.add(
            AgentConversationItem.text(
              role: 'user',
              content:
                  'You echoed the raw web-search results instead of answering. '
                  'Use the search results already provided to answer the user directly now. '
                  'Do not repeat the envelope or call web_search again.',
            ),
          );
          _emit(const AgentResponseDiscarded());
          _emit(
            const AgentStatusChanged(
              'Search results received; preparing answer…',
            ),
          );
          continue;
        }
        _calls = reply.toolCalls;
        _results.clear();
        history.add(
          _calls.isEmpty
              ? AgentConversationItem.text(role: 'assistant', content: text)
              : AgentConversationItem.assistantToolCalls(
                  _calls,
                  content: text.isEmpty ? null : text,
                  reasoningContent: reply.reasoning.isEmpty
                      ? null
                      : reply.reasoning,
                  thinkingBlocks: reply.thinkingBlocks,
                ),
        );
        _emit(
          AgentResponseCompleted(
            reply,
            LlmService.stripCompletionMarkers(text),
          ),
        );
        log?.call(
          'iter=$iteration reply history=${history.length} '
          'chars=${text.length} tools=${_calls.length} '
          'prompt_tokens=${reply.promptTokenCount ?? -1} '
          'completion_tokens=${reply.completionTokenCount ?? -1}',
        );
        if (isCancelled) break;
        if (_calls.isEmpty) {
          _state = AgentRunState.completed;
          break;
        }
        final rejection = AgentToolBatch.rejectionReason(
          _calls,
          registry(),
          finishReason: reply.finishReason,
        );
        if (rejection != null) {
          _results.addAll(
            _calls.map(
              (call) => AgentToolResult(
                toolCallId: call.id,
                content: '[Tool call was not executed] $rejection',
                isError: true,
              ),
            ),
          );
          _flushResults();
          _emit(AgentNotice(rejection));
          continue;
        }
        await _executeBatch();
      }
    } on _RunCancelled {
      // cancel() has already finalized the transcript and closed transport.
    } catch (error, stack) {
      if (!isCancelled) {
        _flushResults(missingReason: 'agent failed before execution completed');
        _state = AgentRunState.failed;
        log?.call('error scope=loop type=${error.runtimeType} $stack');
        _emit(AgentRunFailed(AgentStreamLogSanitizer.message(error)));
      }
    } finally {
      if (_state != AgentRunState.paused) _closeModel();
      _emit(AgentRunEnded(_state));
    }
  }

  /// The cursor and accumulated results survive any number of approval pauses.
  /// No model request or compaction runs until the whole batch is finalized.
  Future<void> _executeBatch() async {
    while (_state == AgentRunState.running && _nextCallIndex < _calls.length) {
      final call = _calls[_nextCallIndex++];
      if (call.name == 'bash') {
        final stop = budget.consumeShellCall(DateTime.now());
        if (stop != null) {
          _flushResults(missingReason: 'execution budget reached');
          _stopForBudget(stop);
          break;
        }
      }
      _emit(AgentToolStarted(call));
      if (isCancelled) break;
      AgentToolExecution execution;
      try {
        execution = call.name == 'use_skill'
            ? await _active(_loadSkill(call))
            : await _active(executeTool(call, this));
      } on _RunCancelled {
        rethrow;
      } catch (error) {
        execution = AgentToolExecution.completed(
          AgentToolResult(
            toolCallId: call.id,
            content: '[Tool failed] ${AgentStreamLogSanitizer.message(error)}',
            isError: true,
          ),
        );
      }
      if (isCancelled) break;
      if (execution.paused) {
        _pending = call;
        _state = AgentRunState.paused;
        break;
      }
      final result = execution.result;
      if (result != null) {
        if (result.toolCallId != call.id) {
          throw StateError('Mismatched tool result id.');
        }
        _results.add(result);
        _emit(AgentToolCompleted(result));
      }
      if (isCancelled) break;
      if (execution.stop) {
        _state = AgentRunState.stopped;
        break;
      }
    }
    if (_state == AgentRunState.paused) return;
    _flushResults();
    if (_state == AgentRunState.running) {
      _emit(const AgentStatusChanged('Feedback sent, AI thinking…'));
    }
  }

  void _closeModel() {
    if (_modelClosed) return;
    _modelClosed = true;
    model.close();
  }

  Future<AgentToolExecution> _loadSkill(AgentToolCall call) async {
    final id = call.arguments['skill_id'] as String;
    final body = skills.containsKey(id) && loadSkill != null
        ? await loadSkill!(id)
        : null;
    if (isCancelled) throw const _RunCancelled();
    final content = body == null
        ? '[Skill not found: $id]\n\nAvailable ids: ${skills.keys.join(', ')}. '
              'Proceed without a skill — DO NOT retry the same use_skill tool call.'
        : '[Skill loaded: $id]\n\n$body';
    _emit(AgentSkillLoaded(id, skills[id] ?? '', body != null));
    return AgentToolExecution.completed(
      AgentToolResult(
        toolCallId: call.id,
        content: content,
        isError: body == null,
      ),
    );
  }

  void _flushResults({String missingReason = 'task stopped before execution'}) {
    if (_calls.isEmpty) return;
    history.add(
      AgentConversationItem.toolResults(
        AgentToolBatch.completeResults(
          _calls,
          _results,
          missingReason: missingReason,
        ),
      ),
    );
    _calls = const [];
    _results.clear();
    _nextCallIndex = 0;
  }

  void _stopForBudget(AgentBudgetStop stop) {
    final reason = switch (stop.limit) {
      AgentBudgetLimit.modelRequests => 'model request limit reached',
      AgentBudgetLimit.shellCalls => 'shell command limit reached',
      AgentBudgetLimit.elapsed => 'time limit reached',
    };
    _stop('[Agent run stopped] $reason.');
  }

  void _stop(String text) {
    _state = AgentRunState.stopped;
    history.add(AgentConversationItem.text(role: 'assistant', content: text));
    _emit(AgentNotice(text));
  }

  Future<void> _compact({bool force = false}) async {
    final outcome = await _active(
      const AgentConversationManager().compactIfNeeded(
        history: history,
        budget: contextBudget,
        lastPromptTokenCount: lastPromptTokenCount,
        force: force,
        isCurrent: () => !isCancelled,
        onStart: () => _emit(const AgentStatusChanged('Compressing context…')),
        summarize: (prompt) =>
            isCancelled ? Future<String?>.value(null) : model.summarize(prompt),
      ),
    );
    if (isCancelled) return;
    _emit(const AgentStatusChanged(null));
    if (outcome == AgentCompactionOutcome.summarized ||
        outcome == AgentCompactionOutcome.trimmed) {
      lastPromptTokenCount = null;
      log?.call('context_compaction result=${outcome.name}');
    }
  }

  Future<AgentModelReply> _readResponse() async {
    var recoveredContext = false;
    const maxAttempts = AgentStreamRetryPolicy.maxRateLimitRetries + 1;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (isCancelled) throw const _RunCancelled();
      var reply = const AgentModelReply();
      try {
        await _active(() async {
          await for (final event in model.stream(List.unmodifiable(history))) {
            if (isCancelled) throw const _RunCancelled();
            reply = reply.add(event);
            _emit(AgentResponseUpdated(reply));
          }
        }());
        return reply;
      } on _RunCancelled {
        rethrow;
      } catch (error) {
        if (isCancelled) throw const _RunCancelled();
        final empty =
            reply.text.isEmpty &&
            reply.reasoning.isEmpty &&
            reply.toolCalls.isEmpty;
        final message = AgentStreamLogSanitizer.message(error).toLowerCase();
        if (empty &&
            !recoveredContext &&
            (message.contains('context length') ||
                message.contains('context_length') ||
                message.contains('maximum context') ||
                message.contains('too many tokens'))) {
          recoveredContext = true;
          await _compact(force: true);
          if (isCancelled) throw const _RunCancelled();
          model.reset();
          continue;
        }
        final rateLimited =
            error is LlmHttpException && error.statusCode == 429 ||
            RegExp(
              r'\bhttp\s*429\b|\bstatus(?:\s+code)?[=: ]+429\b',
            ).hasMatch(message) ||
            message.contains('rate limit') ||
            message.contains('too many requests') ||
            message.contains('resource_exhausted');
        final transient =
            error is HttpException ||
            error is SocketException ||
            message.contains('handshakeexception') ||
            message.contains('tlsexception') ||
            message.contains('connection closed');
        final delay = AgentStreamRetryPolicy.delayAfterAttempt(
          attempt,
          isRateLimited: rateLimited,
        );
        if (!AgentStreamRetryPolicy.canRetry(
              attempt: attempt,
              hasText: reply.text.isNotEmpty,
              hasReasoning: reply.reasoning.isNotEmpty,
              hasToolCalls: reply.toolCalls.isNotEmpty,
              isActive: !isCancelled,
              isTransient: transient,
              isRateLimited: rateLimited,
            ) ||
            delay == null) {
          rethrow;
        }
        model.reset();
        log?.call(
          'stream_retry attempt=$attempt/$maxAttempts backoff_ms=${delay.inMilliseconds} '
          'msg=${AgentStreamLogSanitizer.message(error)}',
        );
        if (rateLimited) {
          _emit(
            const AgentStatusChanged('Rate limited. Retrying in 3 seconds…'),
          );
        }
        await _active(_delay(delay));
        if (rateLimited) {
          _emit(const AgentStatusChanged('Retrying after rate limit…'));
        }
      }
    }
    throw StateError('Model retry attempts exhausted.');
  }
}

class _RunCancelled implements Exception {
  const _RunCancelled();
}
