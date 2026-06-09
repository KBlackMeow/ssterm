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
    // The truncation budget is denominated in BYTES (LLM context windows are
    // tokenised from UTF-8), but Dart's `String.length` returns UTF-16 code
    // units — for CJK / Emoji output a 4 KB Dart-length head can be ≥ 12 KB
    // on the wire.  Measure once in UTF-8 and reuse.
    final rawBytes = utf8.encode(raw);
    final body = _truncateForLlmBytes(rawBytes);
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
    if (rawBytes.length > _kMaxFeedbackBytes) {
      header.writeln('[feedback_truncated=true reason="middle elided to fit context; ${rawBytes.length} bytes captured, ~8 KB sent"]');
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

  /// Byte-accurate version of `_truncateForLlm`.  Slices on UTF-8 byte
  /// boundaries; `allowMalformed: true` replaces any straddled multi-byte
  /// sequence at the cut points with U+FFFD instead of throwing.
  String _truncateForLlmBytes(List<int> bytes) {
    if (bytes.length <= _kMaxFeedbackBytes) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    final head = utf8.decode(
      bytes.sublist(0, _kFeedbackHeadBytes),
      allowMalformed: true,
    );
    final tail = utf8.decode(
      bytes.sublist(bytes.length - _kFeedbackTailBytes),
      allowMalformed: true,
    );
    final elided = bytes.length - _kFeedbackHeadBytes - _kFeedbackTailBytes;
    return '$head\n... [$elided bytes elided] ...\n$tail';
  }

  /// Transient stream errors that we'll retry ONCE if nothing has been
  /// yielded yet.  Keeps the agent loop alive across DeepSeek's frequent
  /// "connection closed while receiving data" hiccups (and similar TLS /
  /// socket flakiness on the other providers) without retrying after the
  /// model has already started speaking — partial chunks aren't safe to
  /// replay because re-streaming would duplicate the head of the reply.
  bool _isTransientStreamError(Object e) {
    if (e is HttpException) return true;
    if (e is SocketException) return true;
    // Match-by-string for exceptions whose classes we don't import.
    // `dart:io`'s `HandshakeException` and `TlsException` extend
    // `IOException` and surface via `chatStream`'s underlying HttpClient.
    final s = e.toString();
    return s.contains('HandshakeException') ||
        s.contains('TlsException') ||
        s.contains('Connection closed');
  }

  Future<String?> _streamAiResponse(
    int gen,
    int historyLenBefore,
    _ChatMessage aiMsg,
    AgentConfig config,
  ) async {
    String fullText = '';
    String reasoningText = '';

    // Outer retry loop: at most one extra attempt, and only when the
    // first attempt yielded zero content AND failed with a transient
    // network error.  Anything more aggressive would risk duplicating
    // half-streamed answers.
    const maxAttempts = 2;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
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

      fullText = '';
      reasoningText = '';
      var scheduled = false;
      // Once the stream completes (success OR error), block all pending
      // post-frame callbacks from clobbering `aiMsg.text` with the
      // half-processed `stripStreamingMarkers` view AFTER the agent
      // loop has applied the final `stripCompletionMarkers` view.
      // Without this guard, the very last in-flight callback can race
      // the stream-end `setState` and reintroduce trailing blank lines
      // or partial markers into the rendered card.
      var streamDone = false;
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
              if (!mounted || streamDone || gen != _generation) return;
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
            });
          }
        }
        streamDone = true;
        if (mounted) {
          setState(() {
            aiMsg.text = LlmService.stripStreamingMarkers(fullText);
            aiMsg.reasoning = reasoningText.isNotEmpty ? reasoningText : null;
          });
        }
        // Stream finished cleanly — break out of the retry loop.
        break;
      } catch (e) {
        streamDone = true;
        // Catch EVERYTHING — stream errors, SSE parse failures, etc.
        final canRetry = attempt < maxAttempts &&
            fullText.isEmpty &&
            reasoningText.isEmpty &&
            mounted &&
            gen == _generation &&
            _isTransientStreamError(e);
        if (canRetry) {
          _logAgent(
            'stream_retry attempt=$attempt/$maxAttempts '
            'type=${e.runtimeType} msg=${_logQuote('$e')}',
          );
          _cancelStream = null;
          // Brief backoff so we don't hammer a flapping endpoint.
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!mounted || gen != _generation) return null;
          continue;
        }
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
    }

    if (!mounted || gen != _generation) return null;
    return fullText;
  }

  Future<String?> _runWebSearch({
    required int gen,
    required int iter,
    required String query,
    required bool enabled,
    int? turnId,
  }) async {
    // Optional `t=N ` prefix mirrors the per-turn tag the main loop adds
    // to its own log lines.  Without it the `web_search_ok` line would
    // be the only intra-turn record missing the prefix and would look
    // visually orphaned between two `t=N iter=N …` lines.
    final tp = turnId == null ? '' : 't=$turnId ';
    if (!enabled) {
      _logAgent(
          '${tp}iter=$iter web_search_skip reason=disabled query=${_logQuote(query)}');
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
        '${tp}iter=$iter web_search_ok results=${results.length} '
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
        '${tp}iter=$iter web_search_err kind=${e.kind.name} '
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
        '${tp}iter=$iter web_search_crash type=${e.runtimeType} '
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
    int? turnId,
  }) async {
    // See `_runWebSearch` for the rationale behind the `tp` prefix —
    // every line emitted while we still consider ourselves "inside" a
    // turn carries the same `t=N ` tag.  Lines that fire AFTER the
    // proposal pauses the loop (the Apply/Reject UI handlers in
    // `_decideWriteProposal`) intentionally stay unprefixed because by
    // then we no longer know which turn they belong to — the user may
    // have started another conversation in the meantime.
    final tp = turnId == null ? '' : 't=$turnId ';
    if (!enabled) {
      _logAgent(
          '${tp}iter=$iter file_write_skip reason=disabled path=${_logQuote(path)}');
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
          '${tp}iter=$iter file_write_skip reason=no_adapter path=${_logQuote(path)}');
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
      _logAgent('${tp}iter=$iter file_write_preview_err kind=${e.kind.name} '
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
      _logAgent('${tp}iter=$iter file_write_preview_crash type=${e.runtimeType} '
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
    _logAgent('${tp}iter=$iter file_write_proposed exists=${preview.exists} '
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

  /// Resolve a dangerous-command [_DangerProposal] when the user
  /// clicks Approve / Reject.  Unlike [_decideWriteProposal] this is
  /// fire-and-forget from the UI's perspective: the agent loop is
  /// already awaiting [_DangerProposal.decision] inside the for-loop
  /// over commands, so we just complete that Future and the loop
  /// resumes in place.
  ///
  /// Idempotent (double-click on Approve is a no-op) and
  /// stale-conversation-safe (if the user fired a new agent turn
  /// between proposal time and click time, the older proposal
  /// silently resolves as rejected without invoking the shell).
  void _decideDangerProposal(_DangerProposal proposal,
      {required bool approve}) {
    if (proposal.decision.isCompleted) return;

    if (proposal.agentGeneration != _generation) {
      // Same staleness handling as [_decideWriteProposal]: visibly
      // reject, complete the future as false so the original loop's
      // staleness check fires and bails out cleanly.
      setState(() => proposal.state = _DangerProposalState.rejected);
      _logAgent('danger_stale rule=${proposal.verdict.patternId}');
      proposal.decision.complete(false);
      return;
    }

    setState(() {
      proposal.state = approve
          ? _DangerProposalState.running
          : _DangerProposalState.rejected;
    });
    _logAgent(approve
        ? 'danger_approved rule=${proposal.verdict.patternId}'
        : 'danger_rejected rule=${proposal.verdict.patternId}');
    proposal.decision.complete(approve);
  }

  /// Structured envelope handed back to the LLM when the user rejects
  /// a dangerous agent command.  The shape mirrors the other agent
  /// feedback envelopes (single bracketed header + key-value-ish body)
  /// so the model's parser sees a familiar pattern.  Wording is
  /// directive — we tell the model what we want it to do next.
  String _formatDangerRejection(String cmd, DangerVerdict verdict) {
    return '[Dangerous command rejected by user]\n'
        'Command: $cmd\n'
        'Matched safety rule: ${verdict.label} (${verdict.patternId})\n'
        'Do NOT retry this command verbatim. '
        'Either propose a safer alternative or ask the user to '
        'clarify what they actually want changed.';
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

    _logAgent('manual_exec cmd=${_logQuote(cmd)}');

    // ── Dangerous-command gate ─────────────────────────────────────────
    //
    // Manual execution goes through the SAME danger gate as the auto-
    // loop path in [_continueAgentLoop]: the command was proposed by
    // the LLM, the user only chose WHEN to run it — clicking Execute
    // is not a safety review.  Without this check, turning auto-
    // execute OFF would silently DOWNGRADE safety, the opposite of
    // what the toggle's name implies.  One knob (`agentConfirmEnabled`)
    // gates both paths so the policy can't drift between them.
    //
    // Tagged `side=agent mode=manual` so log greps stay disambiguated
    // from the auto path's `side=agent iter=N` without breaking
    // existing `side=agent` queries.
    final dangerPolicy = config.dangerousPolicy;
    DangerVerdict? verdict;
    if (dangerPolicy.agentConfirmEnabled) {
      verdict = CommandSafety.danger(cmd, dangerPolicy);
    }

    _DangerProposal? dangerProposal;
    var approved = true;
    if (verdict != null) {
      dangerProposal = _DangerProposal(
        command: cmd,
        verdict: verdict,
        agentGeneration: gen,
      );
      setState(() {
        _messages.add(_ChatMessage.dangerProposal(dangerProposal!));
        _agentLoopStatus = 'Awaiting approval: ${verdict!.label}';
      });
      _scrollToBottom();
      _logSafety('danger_detected side=agent mode=manual '
          'rule=${verdict.patternId} '
          'source=${verdict.source.name}');
      approved = await dangerProposal.decision.future;
      if (!mounted || gen != _generation) {
        _logAgent('manual_exec exit stale_generation');
        return;
      }
    }

    CommandResult? result;
    var loopHandedOff = false;
    try {
      if (!approved) {
        // No shell call.  Mirror the auto path: skip the system card,
        // feed a `[Dangerous command rejected]` envelope back so the
        // LLM sees what happened and can react on the next turn.
        _logSafety('danger_rejected side=agent mode=manual '
            'rule=${verdict!.patternId} '
            'source=${verdict.source.name}');
        _conversationHistory.add({
          'role': 'user',
          'content': _formatDangerRejection(cmd, verdict),
        });
        setState(() => _agentLoopStatus = 'Feedback sent, AI thinking…');
        loopHandedOff = true;
        await _continueAgentLoop(gen, config);
        return;
      }
      if (verdict != null) {
        _logSafety('danger_approved side=agent mode=manual '
            'rule=${verdict.patternId} '
            'source=${verdict.source.name}');
      }

      setState(() => _agentLoopStatus = 'Executing: $cmd');
      _scrollToBottom();

      result = await widget.onExecuteAsync!(
        cmd,
        isCancelled: () => gen != _generation,
      );
      if (!mounted || gen != _generation) return;

      // Flip the danger card to its terminal `ran` state so the chat
      // hierarchy shows: card (approved) → system card (output) →
      // next.  Skipped silently when there was no danger card.
      if (dangerProposal != null) {
        setState(() => dangerProposal!.state = _DangerProposalState.ran);
      }

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
    // Per-process turn counter — bumps once per `_continueAgentLoopBody`
    // invocation (i.e. once per user message that drives an agent
    // loop).  Captured in the two closures below so every log line in
    // THIS turn starts with `t=N` and is greppable as a unit, while
    // adjacent turns get distinct ids.
    final turnId = ++_agentTurnSeq;
    void logIter(String body) => _logAgent('t=$turnId $body');
    void stopIter(int iter, String reason) =>
        _logAgentStop(iter, reason, turnId: turnId);

    var loopIterations = 0;
    while (gen == _generation) {
      if (loopIterations >= _maxLoopIterations) {
        stopIter(loopIterations, 'max_iterations');
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
        // The `maxRemovable` clamp above can turn an even `remove` back
        // into an odd one when the pinned-head count is itself odd
        // (e.g. one bootstrapping system message).  We MUST re-floor to
        // an even count or we'd snip a user-without-its-assistant (or
        // vice-versa) out of the middle, leaving the role pattern
        // broken — which Anthropic rejects with a 400.  Better to keep
        // one extra turn than to corrupt the alternation.
        if (remove.isOdd) remove--;
        if (remove > 0) {
          _conversationHistory.removeRange(
            _kPinnedHeadMessages,
            _kPinnedHeadMessages + remove,
          );
        }
      }

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
      final fullText = await _streamAiResponse(gen, historyLenBefore, aiMsg, config);
      if (fullText == null) {
        stopIter(loopIterations, 'stream_error_or_cancelled');
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
      logIter(
        'iter=$loopIterations reply history=$historyLenAtCall '
        'chars=${fullText.length} '
        'cmds=${commands.length} marker=$markerLabel',
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
          logIter('iter=$loopIterations skill_miss id=$useSkill');
        } else {
          injected = '[Skill loaded: $useSkill]\n\n$body';
          logIter('iter=$loopIterations skill_hit id=$useSkill '
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
            return;
        }
      }

      // Terminus handling.  Model-driven termini (`task_complete`,
      // `ask_user`, `no_commands`) are intentionally NOT re-logged
      // here — the `reply … marker=…` line emitted moments earlier
      // already carries the reason on its `marker=` field, so a
      // separate `stop reason=task_complete` is pure duplication.  We
      // DO still emit a `stop` line for the abnormal termini below
      // (`auto_execute_off`, `no_executor`), because those don't
      // appear in the marker — they are config / environment facts
      // the user needs in the log to make sense of why the loop
      // halted with runnable commands sitting on the chat card.
      if (taskComplete) break;
      if (askUser) break;
      if (commands.isEmpty) break;
      if (!_autoExecute) {
        stopIter(loopIterations, 'auto_execute_off');
        break;
      }
      if (widget.onExecuteAsync == null) {
        stopIter(loopIterations, 'no_executor');
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
        // ── Dangerous-command gate ─────────────────────────────────
        //
        // Runs BEFORE `onExecuteAsync` so a rejected command never
        // touches the shell.  Only fires when:
        //   • The policy enables agent confirmation (default true), AND
        //   • `CommandSafety.danger(...)` returns a verdict.
        //
        // On match we pause this iteration by awaiting a Completer
        // attached to the proposal — much simpler than the
        // file-write pattern of "tear down loop / re-enter on click"
        // because we're mid-for-loop with N remaining commands to
        // process.  When the user clicks Approve/Reject,
        // [_decideDangerProposal] completes the future and the loop
        // resumes in place.
        //
        // Skipping a rejected command synthesises a structured
        // `[Dangerous command rejected]` feedback line — the LLM sees
        // it on the next turn and can decide what to do (typically
        // pick a less destructive alternative or ask the user).
        final dangerPolicy = config.dangerousPolicy;
        DangerVerdict? verdict;
        if (dangerPolicy.agentConfirmEnabled) {
          verdict = CommandSafety.danger(commands[i], dangerPolicy);
        }

        bool approved = true;
        _DangerProposal? dangerProposal;
        if (verdict != null) {
          dangerProposal = _DangerProposal(
            command: commands[i],
            verdict: verdict,
            agentGeneration: gen,
          );
          setState(() {
            _messages.add(_ChatMessage.dangerProposal(dangerProposal!));
            _agentLoopStatus =
                'Awaiting approval: ${verdict!.label}';
          });
          _scrollToBottom();
          _logSafety('t=$turnId danger_detected side=agent iter=$loopIterations '
              'rule=${verdict.patternId} '
              'source=${verdict.source.name}');
          approved = await dangerProposal.decision.future;
          // Generation may have flipped while the user was deciding —
          // bail out exactly like the post-execute staleness check
          // below.
          if (!mounted || gen != _generation) {
            logIter('iter=$loopIterations exit stale_generation');
            return;
          }
        }

        if (!approved) {
          // No shell call.  The "system" command-card is NOT inserted
          // (no command was actually run); the chat history keeps
          // only the danger-proposal card flipped to its rejected
          // state, which is the visible transcript of what happened.
          feedbacks.add(_formatDangerRejection(commands[i], verdict!));
          _logSafety('t=$turnId danger_rejected side=agent iter=$loopIterations '
              'rule=${verdict.patternId} '
              'source=${verdict.source.name}');
          continue;
        }
        if (verdict != null) {
          _logSafety('t=$turnId danger_approved side=agent iter=$loopIterations '
              'rule=${verdict.patternId} '
              'source=${verdict.source.name}');
        }

        setState(() => _agentLoopStatus = 'Executing: ${commands[i]}');
        _scrollToBottom();

        final result = await widget.onExecuteAsync!(
          commands[i],
          isCancelled: () => gen != _generation,
        );
        if (!mounted || gen != _generation) {
          logIter('iter=$loopIterations exit stale_generation');
          return;
        }

        // Flip the danger card to its terminal `ran` state so the
        // chat-card hierarchy shows: card (approved) → system card
        // (output) → next.  Without this the card would visually
        // remain in `running` forever even though the command has
        // long finished.
        if (dangerProposal != null) {
          setState(() => dangerProposal!.state = _DangerProposalState.ran);
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

}
