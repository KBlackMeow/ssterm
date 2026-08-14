// `setState` is `@protected` on the [State] class; calling it from an
// extension method counts as outside an instance member to the analyzer.
// This pattern is safe because the extension is library-scoped to
// part-of `ai_assistant_panel.dart` and only mixed into the private
// `_AiAssistantOverlayState`.
// ignore_for_file: invalid_use_of_protected_member

part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// Agent conversation and command-execution loop.
//
// Extracted from `ai_assistant_panel.dart` as an extension on the
// (private) `_AiAssistantOverlayState` so it keeps direct access to the
// state's controllers, conversation history, generation counter, and
// notification helpers without widening any visibility.
//
// What lives here:
//   • Command feedback envelope formatters (LLM-facing).
//   • The user-typed `_agentRespond` entry point.
//   • `_continueAgentLoop`/`_continueAgentLoopBody` — the actual loop,
//     including the per-command confirm/execute gate every proposed
//     command goes through (dangerous or not, auto-execute or manual).
//
// What stays in the main file:
//   • Panel widget construction and small UI helpers.
//   • `_cancelAgent`, `_send`, slash-command dispatcher, `_clearChat`,
//     `_showHelp` — all keyboard / input-side glue.
// ───────────────────────────────────────────────────────────────────────────

extension _AiAgentLoopExt on _AiAssistantOverlayState {
  String _formatCommandFeedback(
    String cmd,
    CommandResult? result, {
    String? toolCallId,
    String toolName = 'bash',
    CommandRiskAssessment? risk,
  }) {
    return _commandFeedbackFormatter.format(
      cmd,
      result,
      toolCallId: toolCallId,
      toolName: toolName,
      risk: risk,
    );
  }

  /// Transient stream errors that we'll retry if nothing has been
  /// yielded yet.  Keeps the agent loop alive across DeepSeek's frequent
  /// "connection closed while receiving data" hiccups (and similar TLS /
  /// socket flakiness on the other providers) without retrying after the
  /// model has already started speaking — partial chunks aren't safe to
  /// replay because re-streaming would duplicate the head of the reply.

  Future<void> _agentRespond(String userText) async {
    final int gen = ++_generation;
    final config = widget.agentConfig;
    if (config == null) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _messages.add(
          _ChatMessage.ai(
            text: '',
            error:
                'Agent is not configured. Go to Settings → Agent to set it up.',
          ),
        );
      });
      return;
    }

    _markAgentBusy();

    // The agent loop receives direct stdout/stderr from the independent
    // background executor. Visible-terminal scrollback is never included.
    //
    // Skill catalogue: lives inside the system prompt (see
    // [LlmService._buildSkillsBlock]) — Cursor-style.  No per-turn
    // injection needed here, the model already sees every enabled skill
    // listed in `<available_skills>` at the top of every call.
    //
    // Session context (<session_context> block): injected ONLY on the
    // first user turn of a fresh conversation.  Carries the active
    // tab's working directory + HOME so the model can emit absolute
    // file-write paths from turn 1 instead of having to guess and then
    // recover from a `[File write failed]` envelope.  Subsequent turns
    // skip the block — `cd`s the agent itself runs are tracked via the
    // `[Command executed]` feedback the loop already produces.
    final String body;
    if (_conversationHistory.isEmpty) {
      final ctx = await _buildSessionContext();
      body = ctx == null ? userText : '$ctx\n\n$userText';
    } else {
      // The system prompt describes the Flutter host, which can be Windows
      // even when this panel executes commands inside WSL. Repeat the compact
      // per-tab override on later turns so an already-open WSL conversation
      // corrects its command dialect without requiring a new chat.
      final environment = widget.executionEnvironment;
      body = environment == null || environment.isEmpty
          ? userText
          : '<command_environment>$environment</command_environment>\n\n$userText';
    }
    _conversationHistory.add({'role': 'user', 'content': body});

    await _continueAgentLoop(gen, config);
  }

  /// Build a small `<session_context>` block describing the active
  /// tab's environment so the LLM can emit absolute file-write paths
  /// AND reason about relative dates from turn 1.
  ///
  /// Delegates the actual string formatting to [SessionContext.build]
  /// so the format is pure-Dart unit-testable (see
  /// `test/services/session_context_test.dart`).  This wrapper exists
  /// only to gather the inputs from the active tab's adapter +
  /// system clock.
  ///
  /// Always returns a non-null string today — the date/time line alone
  /// is worth the few tokens even when the adapter is missing.  The
  /// caller still tolerates null for backwards safety in case a future
  /// build path decides to suppress the block entirely.
  Future<String?> _buildSessionContext() async {
    final adapter = widget.fileSystemAdapter;
    String? home;
    if (adapter != null) {
      try {
        home = await adapter.homeDirectory();
      } catch (_) {
        home = null;
      }
    }
    return SessionContext.build(
      activeTab: adapter?.label,
      cwd: adapter?.currentDirectory,
      home: home,
      executionEnvironment: widget.executionEnvironment,
      now: DateTime.now(),
    );
  }

  void _markAgentBusy() {
    setState(() {
      _agentBusy = true;
    });
  }

  Future<void> _continueAgentLoop(int gen, AgentConfig config) async {
    if (_streamSessionGeneration != gen || _streamSession == null) {
      _streamSession?.close(force: true);
      _streamSession = AgentStreamClientSession();
      _streamSessionGeneration = gen;
    }
    final streamSession = _streamSession!;
    _streamSessionPausedGeneration = null;
    try {
      await _continueAgentLoopBody(gen, config, streamSession: streamSession);
    } catch (e, st) {
      _logAgent(
        'error scope=loop type=${e.runtimeType} msg=${_logQuote('$e')}',
      );
      stdout.writeln(st);
      if (mounted && gen == _generation) {
        setState(() {
          _messages.add(
            _ChatMessage.ai(text: '', error: 'Agent loop crashed: $e'),
          );
        });
      }
    } finally {
      if (_streamSessionPausedGeneration != gen) {
        streamSession.close();
        if (identical(_streamSession, streamSession)) {
          _streamSession = null;
          _streamSessionGeneration = null;
        }
      }
      if (mounted && gen == _generation) {
        setState(() {
          _agentBusy = false;
          _agentLoopStatus = null;
        });
      }
    }
  }

  Future<void> _continueAgentLoopBody(
    int gen,
    AgentConfig config, {
    required AgentStreamClientSession streamSession,
  }) async {
    // Per-process turn counter — bumps once per `_continueAgentLoopBody`
    // invocation (i.e. once per user message that drives an agent
    // loop).  Captured in the two closures below so every log line in
    // THIS turn starts with `t=N` and is greppable as a unit, while
    // adjacent turns get distinct ids.
    final turnId = ++_agentTurnSeq;
    void logIter(String body) => _logAgent('t=$turnId $body');
    void stopIter(int iter, String reason) =>
        _logAgentStop(iter, reason, turnId: turnId);

    final budget = AgentExecutionBudget();
    var loopIterations = 0;
    agentLoop:
    while (gen == _generation) {
      final modelBudgetStop = budget.consumeModelRequest(DateTime.now());
      if (modelBudgetStop != null) {
        _recordAgentRunStopped(modelBudgetStop);
        stopIter(loopIterations, 'budget_${modelBudgetStop.limit.name}');
        break;
      }
      loopIterations++;

      final historyLenBefore = _conversationHistory.length;
      final aiMsg = _ChatMessage.ai(text: '');
      setState(() => _messages.add(aiMsg));

      // Truncate history — but pin the first [_kPinnedHeadMessages] (the
      // user's goal + the first AI reply) so the agent never forgets WHAT
      // it was asked to do. Native tool calls and results form one atomic
      // transcript group, so trimming must not split them.
      await _compactHistoryIfNeeded(gen, config);
      if (gen != _generation) break;

      // --- AI call ---
      // Structured one-line logs, greppable; see `_logAgent` /
      // `_logAgentStop` at the bottom of this file for the schema.  We
      // intentionally DO NOT emit a separate `iter=N start …` line per
      // iteration any more — the post-call `iter=N reply …` line now
      // carries `history=` too, so a missing `reply` line for the
      // latest iter is itself the "LLM call in flight" signal.  Cuts
      // one line of pure heartbeat noise from every iteration on the
      // happy path.
      final historyLenAtCall = _conversationHistory.length;
      final streamResult = await _streamAiResponse(
        gen,
        historyLenBefore,
        aiMsg,
        config,
        streamSession: streamSession,
      );
      if (streamResult == null) {
        stopIter(loopIterations, 'stream_error_or_cancelled');
        break;
      }

      final resolvedStreamResult = streamResult;
      _lastAgentPromptTokenCount = resolvedStreamResult.promptTokenCount;
      final fullText = resolvedStreamResult.text;
      final protocolText = LlmService.stripForgedCommandFeedback(fullText);
      final nativeToolCalls = resolvedStreamResult.toolCalls
          .map(
            (call) => ToolCall(
              id: call.id,
              name: call.name,
              arguments: call.arguments,
            ),
          )
          .toList(growable: false);
      final toolCalls = nativeToolCalls.isNotEmpty
          ? nativeToolCalls
          : LlmService.extractToolCalls(protocolText);
      const droppedToolCallCount = 0;
      final incompleteError = LlmService.incompleteStreamError(
        text: protocolText,
        hasReasoning: resolvedStreamResult.hasReasoning,
        toolCallCount: toolCalls.length,
        finishReason: resolvedStreamResult.finishReason,
        malformedEventCount: resolvedStreamResult.malformedEventCount,
      );
      if (incompleteError != null) {
        logIter(
          'iter=$loopIterations error incomplete_reply '
          'finish_reason=${_logQuote(resolvedStreamResult.finishReason ?? 'unavailable')} '
          'malformed_events=${resolvedStreamResult.malformedEventCount}',
        );
        setState(() {
          _messages.add(_ChatMessage.ai(text: '', error: incompleteError));
        });
        _scrollToBottom();
        break;
      }
      final shellToolCalls = toolCalls.where((call) => call.isShell).toList();
      final commands = shellToolCalls
          .map((call) => call.command?.trim())
          .whereType<String>()
          .where((cmd) => cmd.isNotEmpty)
          .toList();
      if (resolvedStreamResult.toolCalls.isEmpty) {
        _conversationHistory.add({
          'role': 'assistant',
          'content': protocolText,
        });
      } else {
        _conversationHistory.add(
          AgentConversationItem.assistantToolCalls(
            resolvedStreamResult.toolCalls,
            content: protocolText.isEmpty ? null : protocolText,
          ),
        );
      }
      final displayText = LlmService.stripCompletionMarkers(protocolText);
      aiMsg.text = displayText;
      setState(() {
        if (toolCalls.isNotEmpty) {
          _messages.add(_ChatMessage.toolCalls(toolCalls));
        }
      });
      _scrollToBottom();

      final taskComplete = LlmService.hasTaskCompleteMarker(protocolText);
      final askUser = LlmService.hasAskUserMarker(protocolText);
      ToolCall? useSkillTool;
      ToolCall? webSearchTool;
      ToolCall? writeFileTool;
      ToolCall? editFileTool;
      ToolCall? askUserQuestionTool;
      final mcpToolCalls = <ToolCall>[];
      for (final call in toolCalls) {
        if (useSkillTool == null && call.isUseSkill && call.skillId != null) {
          useSkillTool = call;
        }
        if (webSearchTool == null && call.isWebSearch && call.query != null) {
          webSearchTool = call;
        }
        if (writeFileTool == null &&
            call.isWriteFile &&
            call.path != null &&
            call.content != null) {
          writeFileTool = call;
        }
        if (editFileTool == null &&
            call.isEditFile &&
            call.path != null &&
            call.oldString != null &&
            call.newString != null &&
            call.oldString != call.newString) {
          editFileTool = call;
        }
        if (askUserQuestionTool == null &&
            call.isAskUserQuestion &&
            call.question != null &&
            call.header != null &&
            call.options.length >= 2) {
          askUserQuestionTool = call;
        }
        if (call.isMcp &&
            call.mcpServerId != null &&
            call.mcpToolName != null) {
          mcpToolCalls.add(call);
        }
      }
      final useSkill =
          useSkillTool?.skillId ??
          LlmService.extractUseSkillMarker(protocolText);
      final webQuery =
          webSearchTool?.query ??
          LlmService.extractWebSearchQuery(protocolText);
      final markerWriteFile = LlmService.extractWriteFile(protocolText);
      final writeFile = writeFileTool == null
          ? markerWriteFile
          : (path: writeFileTool.path!, content: writeFileTool.content!);
      final markerLabel = taskComplete
          ? 'task_complete'
          : (askUser
                ? 'ask_user'
                : (askUserQuestionTool != null
                      ? 'ask_user_question'
                      : (useSkill != null
                            ? 'use_skill:$useSkill'
                            : (webQuery != null
                                  ? 'web_search'
                                  : (writeFile != null
                                        ? 'write_file'
                                        : (editFileTool != null
                                              ? 'edit_file'
                                              : 'none'))))));
      logIter(
        'iter=$loopIterations reply history=$historyLenAtCall '
        'chars=${fullText.length} '
        'protocol_chars=${protocolText.length} '
        'tools=${toolCalls.length} dropped_tools=$droppedToolCallCount '
        'shell_tools=${shellToolCalls.length} '
        'cmds=${commands.length} marker=$markerLabel '
        'finish_reason=${_logQuote(resolvedStreamResult.finishReason ?? 'unavailable')} '
        'malformed_events=${resolvedStreamResult.malformedEventCount}',
      );

      if (fullText.isEmpty) {
        // Empty replies usually mean the provider returned no content blocks
        // (rate limit fallback, content-policy refusal, etc.).  Surface as a
        // warning so users can spot it in `flutter run` output.
        logIter('iter=$loopIterations warn empty_reply');
      }

      // ── Skill activation ─────────────────────────────────────────────
      // USE_SKILL is intercepted BEFORE the auto-execute checks so it
      // works in BOTH manual and auto modes — the model can pull in a
      // playbook even when the user hasn't ticked auto-execute, because
      // loading a skill doesn't run any shell commands.  When a USE_SKILL
      // turn also (incorrectly) contained a shell tool call, the marker
      // wins and the commands are dropped, matching how TASK_COMPLETE /
      // ASK_USER behave today — and matching what the system prompt
      // tells the model to expect.
      if (useSkill != null) {
        // Defence in depth: even though disabled skills are filtered out
        // of the announced catalogue, the model might USE_SKILL one
        // anyway — pulled from training data or from an earlier session
        // it remembers.  Treat that as a miss so the agent loop gives a
        // clean "skill not available" notice instead of silently loading
        // something the user disabled.
        final enabledWhitelist = config.enabledSkills;
        final isAllowed =
            enabledWhitelist == null || enabledWhitelist.contains(useSkill);
        // loadBody is async because BUNDLED dynamic skills produce their
        // body via a Dart function that may embed runtime values (e.g.
        // feature flags, probe output).  None ship by default today, but
        // the path stays async so adding one later doesn't require
        // touching every caller.  Asset-backed skills are pre-cached at
        // init() so the await is a microtask hop, not real I/O.
        final body = isAllowed ? await SkillService.loadBody(useSkill) : null;
        if (!mounted || gen != _generation) return;
        final String injected;
        if (body == null) {
          injected =
              '[Skill not found: $useSkill]\n\nNo skill with this id is installed. Available ids: '
              '${SkillService.skills.map((s) => s.id).join(', ')}. '
              'Proceed without a skill — DO NOT retry the same use_skill tool call.';
          logIter('iter=$loopIterations skill_miss id=$useSkill');
        } else {
          injected = '[Skill loaded: $useSkill]\n\n$body';
          logIter(
            'iter=$loopIterations skill_hit id=$useSkill '
            'body_chars=${body.length}',
          );
        }
        _conversationHistory.add({'role': 'user', 'content': injected});
        setState(() {
          // Transient bottom-of-chat status: cleared once the next AI
          // reply starts streaming.
          _agentLoopStatus = body == null
              ? 'Skill not found: $useSkill'
              : 'Loaded skill: $useSkill';
          // Persistent transcript notice: stays visible after the loop
          // moves on so users can see WHICH skill the model consulted.
          _messages.add(
            _ChatMessage.notice(
              body == null
                  ? '**Skill not found**: `$useSkill`'
                  : '**Loaded skill**: `$useSkill` — ${SkillService.skills.firstWhere(
                      (s) => s.id == useSkill,
                      orElse: () => Skill(id: useSkill, name: useSkill, description: '', assetPath: ''),
                    ).description}',
            ),
          );
        });
        _scrollToBottom();
        // Loop continues so the model immediately gets to read the
        // playbook on the next turn.  We deliberately do NOT count this
        // against the iteration budget cap — but it's already incremented
        // above, which is fine for MVP (a small bias toward shorter runs
        // when many skills are loaded, prevents runaway skill chains).
        continue;
      }

      // ── Web search ──────────────────────────────────────────────────
      // Same intercept-before-execute pattern as USE_SKILL: when the
      // model emits a `web_search` tool call we call Brave, format the
      // results, and inject them as the next user message so the model
      // can read them on its NEXT turn.  Bash blocks in the same turn
      // are dropped (system prompt warns about this); we match the
      // marker-wins behaviour of all other meta turns.
      //
      // Runs in both MANUAL and AUTO modes — same rationale as
      // USE_SKILL: fetching information doesn't run any shell commands
      // on the user's machine, so requiring auto-execute would be
      // surprising.
      if (webQuery != null) {
        final injected = await _runWebSearch(
          gen: gen,
          iter: loopIterations,
          turnId: turnId,
          query: webQuery,
          enabled: config.webSearchEnabled,
        );
        if (!mounted || gen != _generation) return;
        if (injected == null) {
          // Cancelled or generation flipped during the fetch — bail
          // without touching history (the cancel path already cleared
          // the transient status).
          return;
        }
        _conversationHistory.add({'role': 'user', 'content': injected});
        setState(() => _agentLoopStatus = null);
        continue;
      }

      // ── MCP tool calls ──────────────────────────────────────────────
      // MCP tools are structured API calls (not shell commands), so they
      // bypass the auto-execute confirmation gate — same as web_search
      // and use_skill.  The user already approved the server by adding it
      // in Settings.  Errors are surfaced in the chat card and as a
      // feedback envelope so the model can pivot.
      if (mcpToolCalls.isNotEmpty) {
        final feedbacks = <String>[];
        final nativeResults = <AgentToolResult>[];
        for (final call in mcpToolCalls) {
          final serverId = call.mcpServerId!;
          final toolName = call.mcpToolName!;
          final startedAt = DateTime.now().millisecondsSinceEpoch;
          logIter(
            'iter=$loopIterations mcp_call '
            'id=${_logQuote(call.id)} server=${_logQuote(serverId)} '
            'tool=${_logQuote(toolName)} arg_count=${call.mcpParams.length}',
          );

          setState(() => _agentLoopStatus = 'Calling MCP: $toolName');
          _scrollToBottom();

          final result = await _executeMcpCall(gen, call);
          if (!mounted || gen != _generation) return;
          final elapsed = DateTime.now().millisecondsSinceEpoch - startedAt;
          logIter(
            'iter=$loopIterations mcp_result '
            'id=${_logQuote(call.id)} server=${_logQuote(serverId)} '
            'tool=${_logQuote(toolName)} '
            'status=${result.isError ? 'error' : 'ok'} '
            'blocks=${result.content.length} elapsed_ms=$elapsed',
          );

          setState(() {
            _messages.add(
              _ChatMessage.mcpResult(
                serverId: serverId,
                toolName: toolName,
                result: result,
              ),
            );
          });
          _scrollToBottom();

          feedbacks.add(_formatMcpResult(call, result));
          nativeResults.add(
            AgentToolResult(
              toolCallId: call.id,
              content: result.textContent.isEmpty
                  ? 'MCP tool returned ${result.content.length} content block(s).'
                  : result.textContent,
              isError: result.isError,
            ),
          );
        }
        _conversationHistory.add(
          resolvedStreamResult.toolCalls.isEmpty
              ? AgentConversationItem.text(
                  role: 'user',
                  content: feedbacks.join('\n\n'),
                )
              : AgentConversationItem.toolResults([
                  ...nativeResults,
                  for (final call in toolCalls)
                    if (!call.isMcp)
                      AgentToolResult(
                        toolCallId: call.id,
                        content:
                            'Tool call was not executed because this turn is processing MCP calls. Reissue it in a later turn if still needed.',
                        isError: true,
                      ),
                ]),
        );
        setState(() => _agentLoopStatus = 'MCP results sent, AI thinking…');
        continue;
      }

      // ── File-write proposal ─────────────────────────────────────────
      // The marker is intercepted BEFORE we look at shell tool calls,
      // [TASK_COMPLETE], or auto-execute — same precedence as
      // USE_SKILL / WEB_SEARCH.  Unlike those two, the write does NOT
      // run automatically: per the user-ratified design (always-Apply
      // policy) we PAUSE the loop, surface a chat card, and resume
      // only when the user clicks Apply or Reject in
      // [_decideWriteProposal].
      if (writeFile != null) {
        final pauseOutcome = await _proposeFileWrite(
          gen: gen,
          iter: loopIterations,
          turnId: turnId,
          path: writeFile.path,
          content: writeFile.content,
          enabled: config.fileWriteEnabled,
        );
        if (!mounted || gen != _generation) return;
        switch (pauseOutcome) {
          case _WriteProposalOutcome.injectedAndContinue:
            // Disabled / preview-failed / adapter-missing case — we
            // already pushed a rejection envelope into history; resume
            // the loop normally on the next iteration.
            setState(() => _agentLoopStatus = null);
            continue;
          case _WriteProposalOutcome.waitingForUser:
            // Card is shown, loop is paused.  Return so the outer
            // `_continueAgentLoop`'s finally fires and unlocks the
            // terminal / clears _agentBusy; the Apply / Reject click
            // will call _continueAgentLoop again to resume.
            _streamSessionPausedGeneration = gen;
            return;
        }
      }

      // ── File-edit proposal ─────────────────────────────────────────
      // Same intercept-before-execute, pause-for-Apply pattern as
      // write_file — see that section's comment above for the
      // rationale. Match validation (no_match / ambiguous_match)
      // happens INSIDE `_proposeFileEdit`, before any card is shown, so
      // the user never sees a diff card for an edit that's already
      // known to fail.
      if (editFileTool != null) {
        final pauseOutcome = await _proposeFileEdit(
          gen: gen,
          iter: loopIterations,
          turnId: turnId,
          path: editFileTool.path!,
          oldString: editFileTool.oldString!,
          newString: editFileTool.newString!,
          replaceAll: editFileTool.replaceAll,
          enabled: config.fileWriteEnabled,
        );
        if (!mounted || gen != _generation) return;
        switch (pauseOutcome) {
          case _EditProposalOutcome.injectedAndContinue:
            setState(() => _agentLoopStatus = null);
            continue;
          case _EditProposalOutcome.waitingForUser:
            _streamSessionPausedGeneration = gen;
            return;
        }
      }

      // ── Ask-user question (multiple-choice) ─────────────────────────
      // Structured sibling of the bare [ASK_USER] marker: the model
      // supplies concrete candidate answers, we show them as a card,
      // and — unlike write_file/web_search/use_skill — we do NOT end
      // the turn.  We await the user's answer in place (mirrors how
      // `_DangerProposal.decision` is awaited inside the command loop
      // below) so the whole exchange stays inside ONE `turnId`: no
      // `_agentBusy` flicker, no terminal unlock/relock, and the loop
      // calls the LLM again automatically the instant an answer lands.
      if (askUserQuestionTool != null) {
        final proposal = _QuestionProposal(
          question: askUserQuestionTool.question!,
          header: askUserQuestionTool.header!,
          options: askUserQuestionTool.options
              .map(
                (o) =>
                    _QuestionOption(label: o.label, description: o.description),
              )
              .toList(),
          agentGeneration: gen,
        );
        setState(() {
          _messages.add(_ChatMessage.questionProposal(proposal));
          _pendingQuestionProposal = proposal;
          _agentLoopStatus = 'Awaiting answer: ${proposal.header}';
        });
        _scrollToBottom();
        logIter(
          'iter=$loopIterations ask_user_question_shown '
          'header=${_logQuote(proposal.header)} '
          'options=${proposal.options.length}',
        );
        final answer = await proposal.decision.future;
        if (!mounted || gen != _generation) {
          logIter('iter=$loopIterations exit stale_generation');
          return;
        }
        if (answer == null) {
          // Cancelled while awaiting — bail without touching history,
          // mirrors the `webQuery` cancellation-during-fetch path above.
          return;
        }
        setState(() {
          _messages.add(_ChatMessage.user(answer));
          _agentLoopStatus = null;
        });
        _conversationHistory.add({'role': 'user', 'content': answer});
        logIter(
          'iter=$loopIterations ask_user_question_answered chars=${answer.length}',
        );
        _scrollToBottom();
        continue;
      }

      // Terminus handling.  Model-driven termini (`task_complete`,
      // `ask_user`, `no_commands`) are intentionally NOT re-logged
      // here — the `reply … marker=…` line emitted moments earlier
      // already carries the reason on its `marker=` field, so a
      // separate `stop reason=task_complete` is pure duplication.  We
      // DO still emit a `stop` line for the abnormal terminus below
      // (`no_executor`), because it doesn't appear in the marker — it's
      // an environment fact the user needs in the log to make sense of
      // why the loop halted with runnable commands sitting on the chat
      // card.
      if (taskComplete) break;
      if (askUser) break;
      if (commands.isEmpty) break;
      if (widget.onExecuteAsync == null) {
        stopIter(loopIterations, 'no_executor');
        break;
      }

      // --- Execute proposed commands ---
      // Runs every proposed command through the same per-command gate
      // regardless of `_autoExecute` — the toggle no longer decides
      // WHETHER this loop runs, only whether an ORDINARY (non-dangerous)
      // command pauses for confirmation.  Dangerous commands always
      // pause; with auto-execute off, EVERY command pauses (this is
      // what replaced the old direct-execution affordance — see the
      // [_DangerProposal] section comment in ai_assistant_panel_models.dart).
      //
      // Collect every command's structured feedback into ONE user-role
      // message so we never emit consecutive 'user' messages — Anthropic's
      // /v1/messages rejects that with `messages must alternate`.
      //
      // We deliberately don't add duplicate chat-log lines here. Structured
      // feedback and command history already retain the final result.
      final feedbacks = <String>[];
      final nativeResults = <AgentToolResult>[];
      for (var i = 0; i < shellToolCalls.length; i++) {
        final toolCall = shellToolCalls[i];
        final command = toolCall.command!.trim();
        // ── Confirmation gate ────────────────────────────────────────
        //
        // Runs BEFORE `onExecuteAsync` so a rejected command never
        // touches the shell.  Pauses (shows a card, awaits a decision)
        // when EITHER is true:
        //   • `CommandSafety.danger(...)` flagged the command (only
        //     checked when the policy enables agent confirmation), OR
        //   • auto-execute is off — every manual command gets an
        //     explicit confirm now, not just the dangerous ones.
        //
        // On pause we await a Completer attached to the proposal — much
        // simpler than the file-write pattern of "tear down loop /
        // re-enter on click" because we're mid-for-loop with N
        // remaining commands to process.  When the user clicks
        // Approve/Reject, [_decideDangerProposal] completes the future
        // and the loop resumes in place.
        //
        // Skipping a rejected command synthesises a structured
        // rejection feedback line — the LLM sees it on the next turn
        // and can decide what to do (typically pick a different
        // approach or ask the user).
        final dangerPolicy = config.dangerousPolicy;
        final operationalRejection = CommandSafety.reason(command);
        final assessment = CommandRisk.assess(
          command: command,
          aiLevel: toolCall.riskLevel,
          aiReason: toolCall.riskReason,
          policy: dangerPolicy,
        );
        final needsConfirm =
            operationalRejection == null &&
            CommandRisk.needsConfirmation(
              assessment.level,
              autoExecute: _autoExecute,
            );

        bool approved = true;
        _DangerProposal? proposal;
        if (needsConfirm) {
          proposal = _DangerProposal(
            command: command,
            reason: toolCall.reason,
            assessment: assessment,
            agentGeneration: gen,
          );
          _pendingDangerProposal = proposal;
          setState(() {
            _messages.add(_ChatMessage.dangerProposal(proposal!));
            _agentLoopStatus = assessment.level != CommandRiskLevel.normal
                ? 'Awaiting approval: ${assessment.reason}'
                : 'Awaiting confirmation to run command';
          });
          _scrollToBottom();
          if (assessment.level == CommandRiskLevel.dangerous) {
            _logSafety(
              't=$turnId danger_detected side=agent iter=$loopIterations '
              'rule=${assessment.hostPatternId ?? 'ai'} '
              'source=${assessment.hostRuleSource?.name ?? assessment.source.name}',
            );
          } else {
            logIter(
              'iter=$loopIterations confirm_pending cmd=${_logQuote(command)}',
            );
          }
          approved = await proposal.decision.future;
          if (identical(_pendingDangerProposal, proposal)) {
            _pendingDangerProposal = null;
          }
          // Generation may have flipped while the user was deciding —
          // bail out exactly like the post-execute staleness check
          // below.
          if (!mounted || gen != _generation) {
            logIter('iter=$loopIterations exit stale_generation');
            return;
          }
        }

        if (!approved) {
          // No shell call.  The proposal card stays in the transcript,
          // flipped to its rejected state — that's the visible record
          // of what happened; no separate "system" card is added.
          if (assessment.level == CommandRiskLevel.dangerous) {
            _logSafety(
              't=$turnId danger_rejected side=agent iter=$loopIterations '
              'rule=${assessment.hostPatternId ?? 'ai'} '
              'source=${assessment.hostRuleSource?.name ?? assessment.source.name}',
            );
          } else {
            logIter(
              'iter=$loopIterations confirm_rejected cmd=${_logQuote(command)}',
            );
          }
          // A rejection is terminal for this agent task.  In particular,
          // don't aggregate a rejection envelope below: doing so would
          // trigger another LLM request with the rejected command as input.
          break agentLoop;
        }
        if (assessment.level == CommandRiskLevel.dangerous) {
          _logSafety(
            't=$turnId danger_approved side=agent iter=$loopIterations '
            'rule=${assessment.hostPatternId ?? 'ai'} '
            'source=${assessment.hostRuleSource?.name ?? assessment.source.name}',
          );
        }

        if (proposal != null &&
            (proposal.command != command ||
                proposal.agentGeneration != _generation)) {
          logIter('iter=$loopIterations exit stale_or_changed_command');
          return;
        }

        final shellBudgetStop = budget.consumeShellCall(DateTime.now());
        if (shellBudgetStop != null) {
          _recordAgentRunStopped(shellBudgetStop);
          stopIter(loopIterations, 'budget_${shellBudgetStop.limit.name}');
          break agentLoop;
        }

        setState(() => _agentLoopStatus = 'Executing: $command');
        final commandMessage = _ChatMessage.system(
          text: '',
          commandRun: command,
          commandPurpose: toolCall.reason,
          commandExitCode: null,
          commandRisk: assessment,
          commandLastThreeLines: const [],
          commandRunning: true,
        );
        setState(() => _messages.add(commandMessage));
        _scrollToBottom();

        final result = await widget.onExecuteAsync!(
          command,
          isCancelled: () => gen != _generation,
          onUpdate: (update) {
            if (!mounted || gen != _generation) return;
            setState(() {
              commandMessage.commandLastThreeLines = update.lastThreeLines;
            });
            _scrollToBottom();
          },
          onSilence: (lastThreeLines) => _decideSilentCommand(
            gen: gen,
            config: config,
            command: command,
            lastThreeLines: lastThreeLines,
          ),
        );
        if (!mounted || gen != _generation) {
          logIter('iter=$loopIterations exit stale_generation');
          return;
        }

        // Flip the proposal card to its terminal `ran` state so the
        // chat-card hierarchy shows: card (approved) → system card
        // (output) → next.  Without this the card would visually
        // remain in `running` forever even though the command has
        // long finished.
        if (proposal != null) {
          setState(() => proposal!.state = _DangerProposalState.ran);
        }

        setState(() {
          commandMessage.text = result?.output ?? '';
          commandMessage.commandExitCode = result?.exitCode;
          commandMessage.commandRunning = false;
        });
        _scrollToBottom();

        final feedback = _formatCommandFeedback(
          command,
          result,
          toolCallId: toolCall.id,
          toolName: toolCall.name,
          risk: assessment,
        );
        feedbacks.add(feedback);
        nativeResults.add(
          AgentToolResult(
            toolCallId: toolCall.id,
            content: feedback,
            isError: result?.exitCode != null && result!.exitCode != 0,
          ),
        );
      }

      _conversationHistory.add(
        resolvedStreamResult.toolCalls.isEmpty
            ? AgentConversationItem.text(
                role: 'user',
                content: feedbacks.join('\n\n'),
              )
            : AgentConversationItem.toolResults(nativeResults),
      );
      logIter(
        'iter=$loopIterations feedback +${feedbacks.length} '
        'history=${_conversationHistory.length}',
      );
      setState(() => _agentLoopStatus = 'Feedback sent, AI thinking…');
    }
    // Lock release lives in _continueAgentLoop's finally — DON'T duplicate
    // it here, otherwise an early `return` from the inner loop would skip
    // it and the outer wrapper's finally would still need to fire anyway.
  }

  Future<void> _compactHistoryIfNeeded(int gen, AgentConfig config) async {
    final provider = config.current;
    final model = config.resolvedModel;
    final budget = AgentContextBudget.forContextWindow(
      model == null ? null : provider?.modelContextWindows[model],
    );
    final estimatedTokens = AgentContextBudget.estimateHistoryTokens(
      _conversationHistory,
    );
    if (!budget.shouldCompact(
      estimatedTokens: estimatedTokens,
      exactUsageTokens: _lastAgentPromptTokenCount,
      itemCount: _conversationHistory.length,
    )) {
      return;
    }
    final candidate = _conversationHistory.compactionCandidate(
      pinnedItemCount: _kPinnedHeadMessages,
      recentItemCount: _recentHistoryItems,
    );
    if (candidate.isEmpty) {
      _conversationHistory.trimToMaxItems(
        maxItems: _historyItemFallbackLimit,
        pinnedItemCount: _kPinnedHeadMessages,
      );
      return;
    }
    if (mounted) setState(() => _agentLoopStatus = 'Compressing context…');
    final summary = await LlmService.compactConversation(
      config: config,
      prompt: ConversationCompactor.buildPrompt(
        existingSummary: _conversationHistory.summaryContent ?? '',
        items: candidate,
      ),
    );
    if (mounted && gen == _generation) {
      setState(() => _agentLoopStatus = null);
    }
    if (gen == _generation && summary != null) {
      _conversationHistory.replaceWithSummary(
        summary: summary,
        pinnedItemCount: _kPinnedHeadMessages,
        recentItemCount: _recentHistoryItems,
      );
      _logAgent('context_compaction result=summary');
    } else if (gen == _generation) {
      _conversationHistory.trimToMaxItems(
        maxItems: _historyItemFallbackLimit,
        pinnedItemCount: _kPinnedHeadMessages,
      );
      _logAgent('context_compaction result=fallback_trim');
    }
  }

  void _recordAgentRunStopped(AgentBudgetStop stop) {
    final reason = switch (stop.limit) {
      AgentBudgetLimit.modelRequests => 'model request limit reached',
      AgentBudgetLimit.shellCalls => 'shell command limit reached',
      AgentBudgetLimit.elapsed => 'time limit reached',
    };
    final text = '[Agent run stopped] $reason.';
    _conversationHistory.add({'role': 'assistant', 'content': text});
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage.notice(text));
      _agentLoopStatus = null;
    });
    _scrollToBottom();
  }
}
