// `setState` is `@protected` on the [State] class; calling it from an
// extension method counts as outside an instance member to the analyzer.
// This pattern is safe because the extension is library-scoped to
// part-of `ai_assistant_panel.dart` and only mixed into the private
// `_AiAssistantOverlayState`.
// ignore_for_file: invalid_use_of_protected_member

part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// Agent loop, tool dispatch, command feedback formatting.
//
// Extracted from `ai_assistant_panel.dart` as an extension on the
// (private) `_AiAssistantOverlayState` so it keeps direct access to the
// state's controllers, conversation history, generation counter, and
// notification helpers without widening any visibility.
//
// What lives here:
//   • Command feedback envelope formatters (LLM-facing).
//   • The streaming LLM call wrapper.
//   • Tool handlers: web search and file write (preview + Apply/Reject).
//   • The user-typed `_agentRespond` and Exec-button `_runManualCommand`
//     entry points.
//   • `_continueAgentLoop`/`_continueAgentLoopBody` — the actual loop.
//
// What stays in the main file:
//   • Panel widget construction and small UI helpers.
//   • `_cancelAgent`, `_send`, slash-command dispatcher, `_clearChat`,
//     `_showHelp` — all keyboard / input-side glue.
// ───────────────────────────────────────────────────────────────────────────

extension _AiAgentLoopExt on _AiAssistantOverlayState {
  String _formatCommandFeedback(String cmd, CommandResult? result) {
    final exit = result?.exitCode;
    final exitStr = exit == null ? 'unknown' : exit.toString();
    final raw = result?.output ?? '';
    final body = _truncateForLlm(raw);
    final header = StringBuffer()
      ..writeln('[Command executed]')
      ..writeln('\$ $cmd')
      ..writeln('[exit_code=$exitStr]');
    // Two distinct kinds of truncation we MUST surface to the LLM:
    //   • capture_truncated: the SHELL produced more bytes than OutputPipe's
    //     256 KB cap kept (or the echo-fallback's 2000-line cap dropped the
    //     head).  Reasoning over an "incomplete tail" is unsound.
    //   • feedback_truncated: capture was complete but we still elide the
    //     middle to fit the LLM context window (head 4 KB + tail 4 KB).
    if (result?.truncated == true) {
      header.writeln('[capture_truncated=true reason="output exceeded ssterm capture cap; head and/or tail may be missing"]');
    }
    if (raw.length > _kMaxFeedbackBytes) {
      header.writeln('[feedback_truncated=true reason="middle elided to fit context; ${raw.length} bytes captured, ~8 KB sent"]');
    }
    if (body.isEmpty) {
      header.writeln('[output: <empty>]');
    } else {
      header
        ..writeln('[output]')
        ..writeln(body);
    }
    return header.toString().trimRight();
  }

  String _truncateForLlm(String text) {
    if (text.length <= _kMaxFeedbackBytes) return text;
    final head = text.substring(0, _kFeedbackHeadBytes);
    final tail = text.substring(text.length - _kFeedbackTailBytes);
    final elided = text.length - _kFeedbackHeadBytes - _kFeedbackTailBytes;
    return '$head\n... [$elided bytes elided] ...\n$tail';
  }

  Future<String?> _streamAiResponse(
    int gen,
    int historyLenBefore,
    _ChatMessage aiMsg,
    AgentConfig config,
  ) async {
    final ({Stream<LlmStreamEvent> stream, void Function() cancel}) result;
    try {
      result = LlmService.chatStream(
        config: config,
        messages: _conversationHistory,
      );
    } catch (e) {
      // Catch EVERYTHING — Error subclasses (StateError, etc.) must not escape.
      _logAgent('error scope=setup_stream type=${e.runtimeType} msg=${_logQuote('$e')}');
      while (_conversationHistory.length > historyLenBefore) {
        _conversationHistory.removeLast();
      }
      if (mounted && gen == _generation) {
        setState(() {
          _messages.removeLast();
          _messages.add(_ChatMessage.ai(text: '', error: '$e'));
        });
      }
      return null;
    }

    _cancelStream = result.cancel;

    String fullText = '';
    String reasoningText = '';
    var scheduled = false;
    try {
      await for (final event in result.stream) {
        if (event.kind == 'reasoning') {
          reasoningText += event.content;
        } else {
          fullText += event.content;
        }
        if (mounted && !scheduled) {
          scheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            scheduled = false;
            if (mounted) {
              setState(() {
                // Hide markers during streaming — without this the user
                // briefly sees `[`, `[TASK`, `[TASK_COMPLETE]` flicker
                // before the post-stream strip runs.  See
                // LlmService.stripStreamingMarkers for partial-marker
                // handling.
                aiMsg.text = LlmService.stripStreamingMarkers(fullText);
                aiMsg.reasoning = reasoningText.isNotEmpty ? reasoningText : null;
              });
              _scrollToBottom();
            }
          });
        }
      }
      if (mounted) {
        setState(() {
          aiMsg.text = LlmService.stripStreamingMarkers(fullText);
          aiMsg.reasoning = reasoningText.isNotEmpty ? reasoningText : null;
        });
      }
    } catch (e) {
      // Catch EVERYTHING — stream errors, SSE parse failures, etc.
      _logAgent('error scope=stream type=${e.runtimeType} msg=${_logQuote('$e')}');
      while (_conversationHistory.length > historyLenBefore) {
        _conversationHistory.removeLast();
      }
      if (mounted) {
        if (gen == _generation) {
          setState(() {
            _messages.removeLast();
            _messages.add(_ChatMessage.ai(text: '', error: 'Stream error: $e'));
          });
        } else {
          setState(() => _messages.removeLast());
        }
      }
      return null;
    } finally {
      _cancelStream = null;
    }

    if (!mounted || gen != _generation) return null;
    return fullText;
  }

  Future<String?> _runWebSearch({
    required int gen,
    required int iter,
    required String query,
    required bool enabled,
  }) async {
    if (!enabled) {
      _logAgent(
          'iter=$iter web_search_skip reason=disabled query=${_logQuote(query)}');
      // Mirror the "[Web search failed]" envelope shape so the model
      // applies the same recovery logic regardless of whether the
      // tool was off at config time vs failed at request time.
      return '[Web search failed]\n'
          'query: "${query.replaceAll('"', r'\"')}"\n'
          'reason: disabled\n'
          'message: Web search is disabled in Settings.\n\n'
          'Tell the user to open Settings → Agent → Web search to enable the tool and add a Brave Search API key. Proceed WITHOUT [WEB_SEARCH]. Do NOT retry the marker.';
    }

    setState(() => _agentLoopStatus = 'Searching the web: $query');
    _scrollToBottom();
    final t0 = DateTime.now().millisecondsSinceEpoch;
    try {
      final results = await WebSearchService.search(query);
      if (!mounted || gen != _generation) return null;
      final elapsed = DateTime.now().millisecondsSinceEpoch - t0;
      _logAgent(
        'iter=$iter web_search_ok results=${results.length} '
        'elapsed_ms=$elapsed query=${_logQuote(query)}',
      );
      setState(() {
        _messages.add(_ChatMessage.notice(
          results.isEmpty
              ? '**Web search**: `$query` — no results'
              : '**Web search**: `$query` — ${results.length} result${results.length == 1 ? '' : 's'}',
        ));
      });
      _scrollToBottom();
      return WebSearchService.formatForLlm(query, results);
    } on WebSearchException catch (e) {
      if (!mounted || gen != _generation) return null;
      _logAgent(
        'iter=$iter web_search_err kind=${e.kind.name} '
        'status=${e.statusCode ?? '-'} query=${_logQuote(query)}',
      );
      setState(() {
        _messages.add(_ChatMessage.notice(
          '**Web search failed**: `$query` — ${e.kind.name}',
        ));
      });
      _scrollToBottom();
      return WebSearchService.formatErrorForLlm(query, e);
    } catch (e) {
      // Catch-all for non-WebSearchException failures (programmer
      // errors, dart:io quirks, etc.) — keep the agent loop alive.
      if (!mounted || gen != _generation) return null;
      _logAgent(
        'iter=$iter web_search_crash type=${e.runtimeType} '
        'msg=${_logQuote('$e')}',
      );
      return '[Web search failed]\n'
          'query: "${query.replaceAll('"', r'\"')}"\n'
          'reason: unknown\n'
          'message: ${e.toString().replaceAll('\n', ' ')}\n\n'
          'Proceed WITHOUT [WEB_SEARCH]. Do NOT retry the marker for the same query.';
    }
  }

  Future<_WriteProposalOutcome> _proposeFileWrite({
    required int gen,
    required int iter,
    required String path,
    required String content,
    required bool enabled,
  }) async {
    if (!enabled) {
      _logAgent(
          'iter=$iter file_write_skip reason=disabled path=${_logQuote(path)}');
      _conversationHistory.add({
        'role': 'user',
        'content': '[File write failed]\n'
            'path: $path\n'
            'reason: disabled\n'
            'message: File write tool is disabled in Settings.\n\n'
            'Tell the user to open Settings → Agent → File write to enable the tool. Proceed WITHOUT [WRITE_FILE_BEGIN]. Do NOT retry the marker.',
      });
      return _WriteProposalOutcome.injectedAndContinue;
    }
    final adapter = widget.fileSystemAdapter;
    if (adapter == null || !adapter.isAvailable) {
      _logAgent(
          'iter=$iter file_write_skip reason=no_adapter path=${_logQuote(path)}');
      _conversationHistory.add({
        'role': 'user',
        'content': FileWriteService.formatErrorForLlm(
          path,
          const FileWriteException(
            FileWriteErrorKind.notSupported,
            'No filesystem adapter is available for this tab (likely a non-terminal tab or an SSH session that hasn\'t finished handshaking yet).',
          ),
        ),
      });
      return _WriteProposalOutcome.injectedAndContinue;
    }

    setState(() =>
        _agentLoopStatus = 'Previewing write: $path (${adapter.label})');
    _scrollToBottom();

    FileWritePreview preview;
    try {
      preview = await adapter.preview(path);
    } on FileWriteException catch (e) {
      if (!mounted || gen != _generation) {
        return _WriteProposalOutcome.injectedAndContinue;
      }
      _logAgent('iter=$iter file_write_preview_err kind=${e.kind.name} '
          'path=${_logQuote(path)}');
      _conversationHistory.add({
        'role': 'user',
        'content': FileWriteService.formatErrorForLlm(path, e),
      });
      return _WriteProposalOutcome.injectedAndContinue;
    } catch (e) {
      if (!mounted || gen != _generation) {
        return _WriteProposalOutcome.injectedAndContinue;
      }
      _logAgent('iter=$iter file_write_preview_crash type=${e.runtimeType} '
          'path=${_logQuote(path)} msg=${_logQuote('$e')}');
      _conversationHistory.add({
        'role': 'user',
        'content': FileWriteService.formatErrorForLlm(
          path,
          FileWriteException(FileWriteErrorKind.io, '$e'),
        ),
      });
      return _WriteProposalOutcome.injectedAndContinue;
    }

    final proposal = _WriteProposal(
      requestedPath: path,
      resolvedPath: preview.resolvedPath,
      content: content,
      preview: preview,
      agentGeneration: gen,
    );
    setState(() {
      _messages.add(_ChatMessage.writeProposal(proposal));
      // Status text reflects the wait — the chat card itself carries
      // the action buttons.
      _agentLoopStatus = 'Awaiting Apply for ${preview.resolvedPath}';
    });
    _scrollToBottom();
    _logAgent('iter=$iter file_write_proposed exists=${preview.exists} '
        'bytes=${content.length} path=${_logQuote(preview.resolvedPath)}');
    return _WriteProposalOutcome.waitingForUser;
  }

  Future<void> _decideWriteProposal(
    _WriteProposal proposal, {
    required bool apply,
    String? reason,
  }) async {
    // Idempotency: double-click on Apply during the in-flight commit
    // must be a no-op.  Same for clicking Reject after Apply has
    // already started.
    if (proposal.state != _WriteProposalState.pending) return;

    // Stale check: if the user fired off a new agent message between
    // proposal time and click time, [_generation] bumped and this
    // proposal is no longer part of an active conversation.  Mark
    // it visually rejected but do NOT touch the new conversation's
    // history (the new loop is busy and didn't ask for this).
    if (proposal.agentGeneration != _generation) {
      setState(() {
        proposal.state = _WriteProposalState.rejected;
        proposal.outcomeMessage =
            'Cancelled — newer conversation started before decision.';
      });
      return;
    }

    final config = widget.agentConfig;
    if (config == null) {
      setState(() {
        proposal.state = _WriteProposalState.failed;
        proposal.outcomeMessage = 'Agent is not configured.';
      });
      return;
    }

    String envelope;
    if (!apply) {
      setState(() {
        proposal.state = _WriteProposalState.rejected;
        proposal.outcomeMessage = reason;
      });
      envelope = FileWriteService.formatRejectionForLlm(
        proposal.requestedPath,
        reason: reason,
      );
      _logAgent('file_write_rejected path=${_logQuote(proposal.resolvedPath)}');
    } else {
      final adapter = widget.fileSystemAdapter;
      if (adapter == null || !adapter.isAvailable) {
        setState(() {
          proposal.state = _WriteProposalState.failed;
          proposal.outcomeMessage =
              'Filesystem adapter is no longer available (tab may have changed).';
        });
        envelope = FileWriteService.formatErrorForLlm(
          proposal.requestedPath,
          const FileWriteException(
            FileWriteErrorKind.notSupported,
            'Filesystem adapter became unavailable between preview and apply.',
          ),
        );
      } else {
        setState(() => proposal.state = _WriteProposalState.applying);
        try {
          final result = await adapter.commit(
            proposal.requestedPath,
            proposal.content,
            expectedMtime: proposal.preview.mtime,
          );
          if (!mounted) return;
          setState(() {
            proposal.state = _WriteProposalState.applied;
            proposal.result = result;
          });
          envelope = FileWriteService.formatSuccessForLlm(result);
          _logAgent('file_write_applied bytes=${result.bytesWritten} '
              'created=${result.created} path=${_logQuote(result.resolvedPath)}');
        } on FileWriteException catch (e) {
          if (!mounted) return;
          setState(() {
            proposal.state = _WriteProposalState.failed;
            proposal.outcomeMessage = e.message;
          });
          envelope = FileWriteService.formatErrorForLlm(
              proposal.requestedPath, e);
          _logAgent('file_write_commit_err kind=${e.kind.name} '
              'path=${_logQuote(proposal.resolvedPath)}');
        } catch (e) {
          if (!mounted) return;
          setState(() {
            proposal.state = _WriteProposalState.failed;
            proposal.outcomeMessage = '$e';
          });
          envelope = FileWriteService.formatErrorForLlm(
            proposal.requestedPath,
            FileWriteException(FileWriteErrorKind.io, '$e'),
          );
          _logAgent('file_write_commit_crash type=${e.runtimeType} '
              'path=${_logQuote(proposal.resolvedPath)}');
        }
      }
    }

    // Inject the envelope and resume the loop where it left off.
    // The loop's generation hasn't changed (we checked above), so
    // _continueAgentLoop will pick up from this synthetic user turn.
    _conversationHistory.add({'role': 'user', 'content': envelope});
    _markAgentBusy(autoExecuteLockTerminal: _autoExecute);
    await _continueAgentLoop(_generation, config);
  }

  Future<void> _agentRespond(String userText) async {
    final int gen = ++_generation;
    final config = widget.agentConfig;
    if (config == null) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _messages.add(_ChatMessage.ai(
          text: '',
          error: 'Agent is not configured. Go to Settings → Agent to set it up.',
        ));
      });
      return;
    }

    _markAgentBusy(autoExecuteLockTerminal: _autoExecute);

    // The agent loop relies entirely on OSC 133 shell-integration capture
    // (with an echo-sentinel fallback) to surface terminal state to the
    // LLM — we no longer prepend a raw terminal-buffer snapshot, which
    // used to duplicate the same data in two formats and bloat context.
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
      body = userText;
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
      now: DateTime.now(),
    );
  }

  Future<void> _runManualCommand(String cmd) async {
    final config = widget.agentConfig;
    if (config == null || widget.onExecuteAsync == null) return;

    if (_agentBusy) _cancelAgent();
    final int gen = ++_generation;
    // Lock terminal during the manual-exec round-trip — same protection as
    // the auto-execute path.  _continueAgentLoop unlocks on completion.
    _markAgentBusy(autoExecuteLockTerminal: true);

    setState(() => _agentLoopStatus = 'Executing: $cmd');
    _scrollToBottom();

    _logAgent('manual_exec cmd=${_logQuote(cmd)}');
    CommandResult? result;
    var loopHandedOff = false;
    try {
      result = await widget.onExecuteAsync!(
        cmd,
        isCancelled: () => gen != _generation,
      );
      if (!mounted || gen != _generation) return;

      setState(() {
        _messages.add(_ChatMessage.system(
          text: result?.output ?? '',
          commandRun: cmd,
          commandExitCode: result?.exitCode,
        ));
      });
      _scrollToBottom();

      _conversationHistory.add({
        'role': 'user',
        'content': _formatCommandFeedback(cmd, result),
      });
      setState(() => _agentLoopStatus = 'Feedback sent, AI thinking…');

      // Hand off to the loop; ITS finally clause will unlock the UI.
      loopHandedOff = true;
      await _continueAgentLoop(gen, config);
    } catch (e, st) {
      // SSH session torn down mid-execution, network drop, etc.  Without
      // this guard the future propagates unhandled and _agentBusy /
      // _terminalLocked stick on forever — the user's only escape is a
      // manual cancel button.
      _logAgent('error scope=manual_exec type=${e.runtimeType} msg=${_logQuote('$e')}');
      stdout.writeln(st);
      if (mounted && gen == _generation) {
        setState(() {
          _messages.add(_ChatMessage.ai(
            text: '',
            error: 'Execution failed: $e',
          ));
        });
      }
    } finally {
      // Only unlock here if we never reached _continueAgentLoop (which
      // owns its own unlock path).  Double-unlocking is harmless but
      // unnecessary; this also prevents a race where the loop's setState
      // fires AFTER our finally already unlocked.
      if (!loopHandedOff && mounted && gen == _generation) {
        setState(() {
          _agentBusy = false;
          _agentLoopStatus = null;
        });
        _setTerminalLocked(false);
      }
    }
  }

  void _markAgentBusy({required bool autoExecuteLockTerminal}) {
    setState(() {
      _agentBusy = true;
    });
    if (autoExecuteLockTerminal) {
      _setTerminalLocked(true);
      // Post-frame so focus settles before we yank it from the terminal.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _unfocusTerminalIfLocked();
      });
    }
  }

  Future<void> _continueAgentLoop(int gen, AgentConfig config) async {
    try {
      await _continueAgentLoopBody(gen, config);
    } catch (e, st) {
      _logAgent('error scope=loop type=${e.runtimeType} msg=${_logQuote('$e')}');
      stdout.writeln(st);
      if (mounted && gen == _generation) {
        setState(() {
          _messages.add(_ChatMessage.ai(text: '', error: 'Agent loop crashed: $e'));
        });
      }
    } finally {
      if (mounted && gen == _generation) {
        setState(() {
          _agentBusy = false;
          _agentLoopStatus = null;
        });
        _setTerminalLocked(false);
      }
    }
  }

  Future<void> _continueAgentLoopBody(int gen, AgentConfig config) async {
    var loopIterations = 0;
    while (gen == _generation) {
      if (loopIterations >= _maxLoopIterations) {
        _logAgentStop(loopIterations, 'max_iterations');
        setState(() {
          _messages.add(_ChatMessage.ai(
            text: '',
            error: 'Max loop iterations ($_maxLoopIterations) reached.',
          ));
        });
        break;
      }
      loopIterations++;

      final historyLenBefore = _conversationHistory.length;
      final aiMsg = _ChatMessage.ai(text: '');
      setState(() => _messages.add(aiMsg));

      // Truncate history — but pin the first [_kPinnedHeadMessages] (the
      // user's goal + the first AI reply) so the agent never forgets WHAT
      // it was asked to do.  Always remove an EVEN number of entries from
      // the middle to preserve the user/assistant role alternation that
      // Anthropic's /v1/messages endpoint enforces.
      if (_conversationHistory.length > _maxHistoryTurns * 2) {
        var remove = _conversationHistory.length - _maxHistoryTurns * 2;
        if (remove.isOdd) remove++;
        final maxRemovable = _conversationHistory.length - _kPinnedHeadMessages;
        if (remove > maxRemovable) remove = maxRemovable;
        if (remove > 0) {
          _conversationHistory.removeRange(
            _kPinnedHeadMessages,
            _kPinnedHeadMessages + remove,
          );
        }
      }

      // --- AI call ---
      // Single-line, structured log lines — easy to grep and tail.  See
      // `_logAgent`/`_logAgentStop` at the bottom of this file for format.
      _logAgent('iter=$loopIterations start history=${_conversationHistory.length}');
      final fullText = await _streamAiResponse(gen, historyLenBefore, aiMsg, config);
      if (fullText == null) {
        _logAgentStop(loopIterations, 'stream_error_or_cancelled');
        break;
      }

      final commands = LlmService.extractCommands(fullText);
      _conversationHistory.add({'role': 'assistant', 'content': fullText});
      final displayText = LlmService.stripCompletionMarkers(fullText);
      aiMsg.text = displayText;
      setState(() {
        aiMsg.commands = commands.isNotEmpty ? commands : null;
      });
      _scrollToBottom();

      final taskComplete = LlmService.hasTaskCompleteMarker(fullText);
      final askUser = LlmService.hasAskUserMarker(fullText);
      final useSkill = LlmService.extractUseSkillMarker(fullText);
      final webQuery = LlmService.extractWebSearchQuery(fullText);
      final writeFile = LlmService.extractWriteFile(fullText);
      final markerLabel = taskComplete
          ? 'task_complete'
          : (askUser
              ? 'ask_user'
              : (useSkill != null
                  ? 'use_skill:$useSkill'
                  : (webQuery != null
                      ? 'web_search'
                      : (writeFile != null ? 'write_file' : 'none'))));
      _logAgent(
        'iter=$loopIterations reply chars=${fullText.length} '
        'cmds=${commands.length} marker=$markerLabel',
      );

      if (fullText.isEmpty) {
        // Empty replies usually mean the provider returned no content blocks
        // (rate limit fallback, content-policy refusal, etc.).  Surface as a
        // warning so users can spot it in `flutter run` output.
        _logAgent('iter=$loopIterations warn empty_reply');
      }

      // ── Skill activation ─────────────────────────────────────────────
      // USE_SKILL is intercepted BEFORE the auto-execute checks so it
      // works in BOTH manual and auto modes — the model can pull in a
      // playbook even when the user hasn't ticked auto-execute, because
      // loading a skill doesn't run any shell commands.  When a USE_SKILL
      // turn also (incorrectly) contained a ```bash block, the marker
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
        final isAllowed = enabledWhitelist == null ||
            enabledWhitelist.contains(useSkill);
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
          injected = '[Skill not found: $useSkill]\n\nNo skill with this id is installed. Available ids: '
              '${SkillService.skills.map((s) => s.id).join(', ')}. '
              'Proceed without a skill — DO NOT retry [USE_SKILL] with the same id.';
          _logAgent('iter=$loopIterations skill_miss id=$useSkill');
        } else {
          injected = '[Skill loaded: $useSkill]\n\n$body';
          _logAgent('iter=$loopIterations skill_hit id=$useSkill '
              'body_chars=${body.length}');
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
          _messages.add(_ChatMessage.notice(
            body == null
                ? '**Skill not found**: `$useSkill`'
                : '**Loaded skill**: `$useSkill` — ${SkillService.skills.firstWhere((s) => s.id == useSkill, orElse: () => Skill(id: useSkill, name: useSkill, description: '', assetPath: '')).description}',
          ));
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
      // model emits `[WEB_SEARCH: <query>]` we call Brave, format the
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

      // ── File-write proposal ─────────────────────────────────────────
      // The marker is intercepted BEFORE we look at ```bash blocks,
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
            return;
        }
      }

      if (!_autoExecute) {
        _logAgentStop(loopIterations, 'auto_execute_off');
        break;
      }
      if (taskComplete) {
        _logAgentStop(loopIterations, 'task_complete');
        break;
      }
      if (askUser) {
        _logAgentStop(loopIterations, 'ask_user');
        break;
      }
      if (commands.isEmpty) {
        _logAgentStop(loopIterations, 'no_commands');
        break;
      }
      if (widget.onExecuteAsync == null) {
        _logAgentStop(loopIterations, 'no_executor');
        break;
      }

      // --- Auto-execute commands ---
      // Collect every command's structured feedback into ONE user-role
      // message so we never emit consecutive 'user' messages — Anthropic's
      // /v1/messages rejects that with `messages must alternate`.
      //
      // We deliberately DON'T log per-command "executing"/"result" lines
      // here — the [capture] layer already logs `start`/`done` with the
      // exit code and byte count, so logging both ends would double the
      // noise without adding information.
      final feedbacks = <String>[];
      for (var i = 0; i < commands.length; i++) {
        setState(() => _agentLoopStatus = 'Executing: ${commands[i]}');
        _scrollToBottom();

        final result = await widget.onExecuteAsync!(
          commands[i],
          isCancelled: () => gen != _generation,
        );
        if (!mounted || gen != _generation) {
          _logAgent('iter=$loopIterations exit stale_generation');
          return;
        }

        setState(() {
          _messages.add(_ChatMessage.system(
            text: result?.output ?? '',
            commandRun: commands[i],
            commandExitCode: result?.exitCode,
          ));
        });
        _scrollToBottom();

        feedbacks.add(_formatCommandFeedback(commands[i], result));
      }

      _conversationHistory.add({
        'role': 'user',
        'content': feedbacks.join('\n\n'),
      });
      _logAgent(
        'iter=$loopIterations feedback +${feedbacks.length} '
        'history=${_conversationHistory.length}',
      );
      setState(() => _agentLoopStatus = 'Feedback sent, AI thinking…');
    }
    // Lock release lives in _continueAgentLoop's finally — DON'T duplicate
    // it here, otherwise an early `return` from the inner loop would skip
    // it and the outer wrapper's finally would still need to fire anyway.
  }

}
