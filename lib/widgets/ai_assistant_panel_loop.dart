// ignore_for_file: invalid_use_of_protected_member

part of 'ai_assistant_panel.dart';

/// Flutter adapter for the headless runner. Rendering never schedules a model
/// turn; user decisions are returned to the runner that requested them.
extension _AiAgentLoopExt on _AiAssistantOverlayState {
  Future<void> _agentRespond(
    String userText, {
    List<AgentImageAttachment> images = const [],
  }) async {
    final gen = ++_generation;
    final config = widget.agentConfig;
    if (config == null) {
      setState(
        () => _messages.add(
          _ChatMessage.ai(
            text: '',
            error:
                'Agent is not configured. Go to Settings → Agent to set it up.',
          ),
        ),
      );
      return;
    }
    _markAgentBusy();
    final String body;
    if (_conversationHistory.isEmpty) {
      final ctx = await _buildSessionContext();
      if (!mounted || gen != _generation) return;
      body = ctx == null ? userText : '$ctx\n\n$userText';
    } else {
      final environment = widget.executionEnvironment;
      body = environment == null || environment.isEmpty
          ? userText
          : '<command_environment>$environment</command_environment>\n\n$userText';
    }
    _conversationHistory.add(
      AgentConversationItem.text(role: 'user', content: body, images: images),
    );
    await SkillService.startupReady;
    if (!mounted || gen != _generation) return;
    final turnId = ++_agentTurnSeq;
    final runner = AgentRunner(
      history: _conversationHistory,
      model: LlmAgentModel(config),
      contextBudget: AgentContextBudget.forContextWindow(
        config.resolvedModel == null
            ? null
            : config.current?.modelContextWindows[config.resolvedModel],
      ),
      lastPromptTokenCount: _lastAgentPromptTokenCount,
      registry: () => AgentToolRegistry.build(
        webSearchEnabled: config.webSearchEnabled,
        fileWriteEnabled: config.fileWriteEnabled,
        skillsEnabled: SkillService.filterEnabled(
          config.enabledSkills,
        ).isNotEmpty,
        mcpTools: config.mcpEnabled ? McpService.allTools : const [],
      ),
      skills: {
        for (final skill in SkillService.filterEnabled(config.enabledSkills))
          skill.id: skill.description,
      },
      loadSkill: SkillService.loadBody,
      executeTool: (call, runner) => _executeAgentTool(
        call,
        runner,
        gen: gen,
        config: config,
        turnId: turnId,
      ),
      log: (message) => _logAgent('t=$turnId $message'),
    );
    _agentRunner = runner;
    _subscribeToRunner(runner, gen);
    await _driveAgentRunner(runner, gen);
  }

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

  void _markAgentBusy() => setState(() => _agentBusy = true);

  Future<void> _driveAgentRunner(
    AgentRunner runner,
    int gen, {
    AgentToolResult? result,
    bool stopAfterResume = false,
  }) async {
    try {
      if (result == null) {
        await runner.run();
      } else {
        await runner.resume(result, stop: stopAfterResume);
      }
    } finally {
      if (mounted && gen == _generation && identical(_agentRunner, runner)) {
        _lastAgentPromptTokenCount = runner.lastPromptTokenCount;
        setState(() {
          _agentBusy = false;
          _agentLoopStatus = null;
        });
        _queueSessionSave();
        _drainQueuedUserInput();
      }
    }
  }

  Future<void> _resumeAgentTool(
    String content, {
    required bool isError,
    bool stop = false,
  }) async {
    final runner = _agentRunner;
    final call = runner?.pendingTool;
    if (runner == null ||
        call == null ||
        runner.state != AgentRunState.paused) {
      return;
    }
    _markAgentBusy();
    await _driveAgentRunner(
      runner,
      _generation,
      stopAfterResume: stop,
      result: AgentToolResult(
        toolCallId: call.id,
        content: content,
        isError: isError,
      ),
    );
  }

  void _subscribeToRunner(AgentRunner runner, int gen) {
    _ChatMessage? response;
    AgentModelReply? latest;
    var scheduled = false;
    var revision = 0;
    runner.subscribe((event) {
      if (!mounted || gen != _generation || !identical(_agentRunner, runner)) {
        return;
      }
      switch (event) {
        case AgentResponseStarted():
          revision++;
          scheduled = false;
          response = _ChatMessage.ai(text: '');
          setState(() {
            _agentLoopStatus = null;
            _messages.add(response!);
          });
        case AgentResponseUpdated(:final reply):
          latest = reply;
          if (scheduled) return;
          scheduled = true;
          final currentRevision = revision;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            scheduled = false;
            if (!mounted || gen != _generation || currentRevision != revision) {
              return;
            }
            final snapshot = latest;
            if (snapshot == null || response == null) return;
            setState(() => _renderAgentReply(response!, snapshot));
            _scrollToBottom();
          });
        case AgentResponseCompleted(:final reply, :final displayText):
          revision++;
          if (response != null) {
            setState(() {
              _renderAgentReply(response!, reply);
              response!.text = displayText;
              if (reply.toolCalls.isNotEmpty) {
                _messages.add(
                  _ChatMessage.toolCalls([
                    for (final call in reply.toolCalls)
                      ToolCall(
                        id: call.id,
                        name: call.name,
                        arguments: call.arguments,
                      ),
                  ]),
                );
              }
            });
          }
        case AgentResponseDiscarded():
          revision++;
          setState(() => _messages.remove(response));
          response = null;
        case AgentStatusChanged(:final text):
          setState(() => _agentLoopStatus = text);
        case AgentNotice(:final text):
          setState(() => _messages.add(_ChatMessage.notice(text)));
        case AgentSkillLoaded(:final id, :final description, :final loaded):
          setState(() {
            _agentLoopStatus = loaded
                ? 'Loaded skill: $id'
                : 'Skill not found: $id';
            _messages.add(
              _ChatMessage.notice(
                loaded
                    ? '**Loaded skill**: `$id` — $description'
                    : '**Skill not found**: `$id`',
              ),
            );
          });
        case AgentRunFailed(:final message):
          revision++;
          setState(
            () => _messages.add(
              _ChatMessage.ai(text: '', error: 'Agent error: $message'),
            ),
          );
        case AgentRunEnded():
          revision++;
        case AgentRunStarted():
        case AgentToolStarted():
        case AgentToolCompleted():
          break;
      }
      _scrollToBottom();
    });
  }

  void _renderAgentReply(_ChatMessage message, AgentModelReply reply) {
    message.text = LlmService.stripStreamingMarkers(reply.text);
    message.reasoning = reply.reasoning.isEmpty ? null : reply.reasoning;
    message.reasoningTokenCount = reply.reasoning.isEmpty
        ? null
        : reply.reasoningTokenCount ??
              LlmService.estimateReasoningTokenCount(reply.reasoning);
    message.hasExactReasoningTokenCount = reply.reasoningTokenCount != null;
  }
}
