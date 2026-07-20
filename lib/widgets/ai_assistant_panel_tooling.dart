// ignore_for_file: invalid_use_of_protected_member

part of 'ai_assistant_panel.dart';

/// Streaming and tool-approval implementation used by the agent loop.
extension _AiAgentToolingExt on _AiAssistantOverlayState {
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
        _logAgent(
          'error scope=setup_stream type=${e.runtimeType} msg=${_logQuote('$e')}',
        );
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
                aiMsg.reasoning = reasoningText.isNotEmpty
                    ? reasoningText
                    : null;
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
        final canRetry =
            attempt < maxAttempts &&
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
        _logAgent(
          'error scope=stream type=${e.runtimeType} msg=${_logQuote('$e')}',
        );
        while (_conversationHistory.length > historyLenBefore) {
          _conversationHistory.removeLast();
        }
        if (mounted) {
          if (gen == _generation) {
            setState(() {
              _messages.removeLast();
              _messages.add(
                _ChatMessage.ai(text: '', error: 'Stream error: $e'),
              );
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
        '${tp}iter=$iter web_search_skip reason=disabled query=${_logQuote(query)}',
      );
      // Mirror the "[Web search failed]" envelope shape so the model
      // applies the same recovery logic regardless of whether the
      // tool was off at config time vs failed at request time.
      return '[Web search failed]\n'
          'query: "${query.replaceAll('"', r'\"')}"\n'
          'reason: disabled\n'
          'message: Web search is disabled in Settings.\n\n'
          'Tell the user to open Settings → Agent → Web search to enable the tool and add a Brave Search API key. Proceed without web_search. Do NOT retry the same web_search tool call.';
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
        _messages.add(
          _ChatMessage.notice(
            results.isEmpty
                ? '**Web search**: `$query` — no results'
                : '**Web search**: `$query` — ${results.length} result${results.length == 1 ? '' : 's'}',
          ),
        );
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
        _messages.add(
          _ChatMessage.notice(
            '**Web search failed**: `$query` — ${e.kind.name}',
          ),
        );
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
          'Proceed without web_search. Do NOT retry the same web_search tool call for the same query.';
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
        '${tp}iter=$iter file_write_skip reason=disabled path=${_logQuote(path)}',
      );
      _conversationHistory.add({
        'role': 'user',
        'content':
            '[File write failed]\n'
            'path: $path\n'
            'reason: disabled\n'
            'message: File write tool is disabled in Settings.\n\n'
            'Tell the user to open Settings → Agent → File write to enable the tool. Proceed without write_file. Do NOT retry the same write_file tool call.',
      });
      return _WriteProposalOutcome.injectedAndContinue;
    }
    final adapter = widget.fileSystemAdapter;
    if (adapter == null || !adapter.isAvailable) {
      _logAgent(
        '${tp}iter=$iter file_write_skip reason=no_adapter path=${_logQuote(path)}',
      );
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

    setState(
      () => _agentLoopStatus = 'Previewing write: $path (${adapter.label})',
    );
    _scrollToBottom();

    FileWritePreview preview;
    try {
      preview = await adapter.preview(path);
    } on FileWriteException catch (e) {
      if (!mounted || gen != _generation) {
        return _WriteProposalOutcome.injectedAndContinue;
      }
      _logAgent(
        '${tp}iter=$iter file_write_preview_err kind=${e.kind.name} '
        'path=${_logQuote(path)}',
      );
      _conversationHistory.add({
        'role': 'user',
        'content': FileWriteService.formatErrorForLlm(path, e),
      });
      return _WriteProposalOutcome.injectedAndContinue;
    } catch (e) {
      if (!mounted || gen != _generation) {
        return _WriteProposalOutcome.injectedAndContinue;
      }
      _logAgent(
        '${tp}iter=$iter file_write_preview_crash type=${e.runtimeType} '
        'path=${_logQuote(path)} msg=${_logQuote('$e')}',
      );
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
    _logAgent(
      '${tp}iter=$iter file_write_proposed exists=${preview.exists} '
      'bytes=${content.length} path=${_logQuote(preview.resolvedPath)}',
    );
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
          _logAgent(
            'file_write_applied bytes=${result.bytesWritten} '
            'created=${result.created} path=${_logQuote(result.resolvedPath)}',
          );
        } on FileWriteException catch (e) {
          if (!mounted) return;
          setState(() {
            proposal.state = _WriteProposalState.failed;
            proposal.outcomeMessage = e.message;
          });
          envelope = FileWriteService.formatErrorForLlm(
            proposal.requestedPath,
            e,
          );
          _logAgent(
            'file_write_commit_err kind=${e.kind.name} '
            'path=${_logQuote(proposal.resolvedPath)}',
          );
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
          _logAgent(
            'file_write_commit_crash type=${e.runtimeType} '
            'path=${_logQuote(proposal.resolvedPath)}',
          );
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
  void _decideDangerProposal(
    _DangerProposal proposal, {
    required bool approve,
  }) {
    if (proposal.decision.isCompleted) return;

    if (proposal.agentGeneration != _generation) {
      // Same staleness handling as [_decideWriteProposal]: visibly
      // reject, complete the future as false so the original loop's
      // staleness check fires and bails out cleanly.
      setState(() => proposal.state = _DangerProposalState.rejected);
      _logAgent('danger_stale rule=${proposal.verdict?.patternId ?? 'none'}');
      proposal.decision.complete(false);
      return;
    }

    setState(() {
      proposal.state = approve
          ? _DangerProposalState.running
          : _DangerProposalState.rejected;
    });
    final ruleTag = proposal.verdict != null
        ? 'rule=${proposal.verdict!.patternId}'
        : 'rule=none';
    _logAgent(
      approve ? 'danger_approved $ruleTag' : 'danger_rejected $ruleTag',
    );
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

  /// Structured envelope handed back to the LLM when the user rejects
  /// an ORDINARY (non-dangerous) command proposed while auto-execute is
  /// off.  Same shape as [_formatDangerRejection] minus the rule fields,
  /// since there's no matched safety rule to report.
  String _formatCommandRejection(String cmd) {
    return '[Command rejected by user]\n'
        'Command: $cmd\n'
        'Do NOT retry this command verbatim. '
        'Either propose a different approach or ask the user to '
        'clarify what they actually want changed.';
  }
}
