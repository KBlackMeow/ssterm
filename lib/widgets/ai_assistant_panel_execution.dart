// ignore_for_file: invalid_use_of_protected_member

part of 'ai_assistant_panel.dart';

/// Host adapter: filesystem, MCP and command execution plus their approval UI.
/// It returns outcomes; model scheduling and transcript pairing belong to Runner.
extension _AiAgentExecutionExt on _AiAssistantOverlayState {
  AgentToolExecution _toolResult(
    ToolCall call,
    String content, {
    bool isError = false,
    List<AgentImageAttachment> images = const [],
  }) => AgentToolExecution.completed(
    AgentToolResult(
      toolCallId: call.id,
      content: content,
      isError: isError,
      images: images,
    ),
  );

  Future<AgentToolExecution> _executeAgentTool(
    AgentToolCall nativeCall,
    AgentRunner runner, {
    required int gen,
    required AgentConfig config,
    required int turnId,
  }) async {
    if (!mounted || gen != _generation || runner.isCancelled) {
      return const AgentToolExecution.stopped();
    }
    final call = ToolCall(
      id: nativeCall.id,
      name: nativeCall.name,
      arguments: nativeCall.arguments,
    );
    final iter = runner.iteration;
    if (call.isWebSearch && call.query != null) {
      final content = await _runWebSearch(
        gen: gen,
        iter: iter,
        turnId: turnId,
        query: call.query!,
        enabled: config.webSearchEnabled,
      );
      return content == null
          ? const AgentToolExecution.stopped()
          : _toolResult(call, content);
    }
    if (call.isReadImage && call.path != null) {
      try {
        final image = await AgentImageAttachmentReader.read(
          path: call.path!,
          workspaceRoot:
              widget.fileSystemAdapter?.currentDirectory ??
              Directory.current.path,
        );
        if (!mounted || gen != _generation) {
          return const AgentToolExecution.stopped();
        }
        setState(() => _agentLoopStatus = 'Image loaded: ${image.displayName}');
        return _toolResult(
          call,
          'Loaded image: ${image.displayName}',
          images: [image],
        );
      } on AgentImageAttachmentException catch (error) {
        return _toolResult(
          call,
          '[Image read failed] ${error.message}',
          isError: true,
        );
      }
    }
    if (call.isReadOutput || call.isReadFile || call.isGrepFile) {
      final result = await AgentReadTools(
        outputStore: _outputStore,
        fileSystem: widget.fileSystemAdapter,
      ).execute(call.name, call.arguments);
      if (!mounted || gen != _generation) {
        return const AgentToolExecution.stopped();
      }
      setState(() => _messages.add(_ChatMessage.notice(result.content)));
      return _toolResult(call, result.content, isError: result.isError);
    }
    if (call.isMcp && call.mcpServerId != null && call.mcpToolName != null) {
      final serverId = call.mcpServerId!;
      final toolName = call.mcpToolName!;
      setState(() => _agentLoopStatus = 'Calling MCP: $toolName');
      final result = await _executeMcpCall(gen, call);
      if (!mounted || gen != _generation) {
        return const AgentToolExecution.stopped();
      }
      setState(
        () => _messages.add(
          _ChatMessage.mcpResult(
            serverId: serverId,
            toolName: toolName,
            result: result,
          ),
        ),
      );
      return _toolResult(
        call,
        result.textContent.isEmpty
            ? 'MCP tool returned ${result.content.length} content block(s).'
            : result.textContent,
        isError: result.isError,
      );
    }
    if (call.isWriteFile && call.path != null && call.content != null) {
      return _proposeFileWrite(
        call: call,
        gen: gen,
        iter: iter,
        turnId: turnId,
        path: call.path!,
        content: call.content!,
        enabled: config.fileWriteEnabled,
      );
    }
    if (call.isEditFile &&
        call.path != null &&
        call.oldString != null &&
        call.newString != null) {
      return _proposeFileEdit(
        call: call,
        gen: gen,
        iter: iter,
        turnId: turnId,
        path: call.path!,
        oldString: call.oldString!,
        newString: call.newString!,
        replaceAll: call.replaceAll,
        enabled: config.fileWriteEnabled,
      );
    }
    if (call.isAskUserQuestion &&
        call.question != null &&
        call.header != null &&
        call.options.length >= 2) {
      final proposal = _QuestionProposal(
        question: call.question!,
        header: call.header!,
        options: [
          for (final option in call.options)
            _QuestionOption(
              label: option.label,
              description: option.description,
            ),
        ],
        agentGeneration: gen,
      );
      setState(() {
        _messages.add(_ChatMessage.questionProposal(proposal));
        _pendingQuestionProposal = proposal;
        _agentLoopStatus = 'Awaiting answer: ${proposal.header}';
      });
      _scrollToBottom();
      final answer = await proposal.decision.future;
      if (!mounted || gen != _generation || answer == null) {
        return const AgentToolExecution.stopped();
      }
      setState(() {
        _messages.add(_ChatMessage.user(answer));
        _agentLoopStatus = null;
      });
      return _toolResult(call, answer);
    }
    if (call.isShell &&
        call.command != null &&
        call.command!.trim().isNotEmpty) {
      return _executeAgentCommand(
        call,
        gen: gen,
        config: config,
        turnId: turnId,
        iter: iter,
      );
    }
    return _toolResult(
      call,
      '[Tool failed] Invalid tool arguments.',
      isError: true,
    );
  }

  Future<AgentToolExecution> _executeAgentCommand(
    ToolCall toolCall, {
    required int gen,
    required AgentConfig config,
    required int turnId,
    required int iter,
  }) async {
    if (widget.onExecuteAsync == null) {
      return AgentToolExecution.stopped(
        AgentToolResult(
          toolCallId: toolCall.id,
          content:
              '[Tool call was not executed: the active tab has no command executor.]',
          isError: true,
        ),
      );
    }
    final command = toolCall.command!.trim();
    final operationalRejection = CommandSafety.reason(command);
    final assessment = CommandRisk.assess(
      command: command,
      aiLevel: toolCall.riskLevel,
      aiReason: toolCall.riskReason,
      policy: config.dangerousPolicy,
    );
    final needsConfirm =
        operationalRejection == null &&
        CommandRisk.needsConfirmation(
          assessment.level,
          autoExecute: _autoExecute,
        );
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
          't=$turnId danger_detected side=agent iter=$iter '
          'rule=${assessment.hostPatternId ?? 'ai'} '
          'source=${assessment.hostRuleSource?.name ?? assessment.source.name}',
        );
      }
      final approved = await proposal.decision.future;
      if (identical(_pendingDangerProposal, proposal)) {
        _pendingDangerProposal = null;
      }
      if (!mounted || gen != _generation) {
        return const AgentToolExecution.stopped();
      }
      if (!approved) {
        if (assessment.level == CommandRiskLevel.dangerous) {
          _logSafety(
            't=$turnId danger_rejected side=agent iter=$iter '
            'rule=${assessment.hostPatternId ?? 'ai'} '
            'source=${assessment.hostRuleSource?.name ?? assessment.source.name}',
          );
        }
        return const AgentToolExecution.stopped();
      }
      if (proposal.command != command ||
          proposal.agentGeneration != _generation) {
        return const AgentToolExecution.stopped();
      }
    }
    if (!mounted || gen != _generation) {
      return const AgentToolExecution.stopped();
    }
    if (assessment.level == CommandRiskLevel.dangerous) {
      _logSafety(
        't=$turnId danger_approved side=agent iter=$iter '
        'rule=${assessment.hostPatternId ?? 'ai'} '
        'source=${assessment.hostRuleSource?.name ?? assessment.source.name}',
      );
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
        setState(
          () => commandMessage.commandLastThreeLines = update.lastThreeLines,
        );
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
      return const AgentToolExecution.stopped();
    }
    setState(() {
      if (proposal != null) proposal.state = _DangerProposalState.ran;
      commandMessage.text = result?.output ?? '';
      commandMessage.commandExitCode = result?.exitCode;
      commandMessage.commandRunning = false;
    });
    _scrollToBottom();
    AgentOutputReference? artifact;
    if (result != null && result.output.isNotEmpty) {
      try {
        artifact = await _outputStore.save(result.output);
      } catch (error) {
        _logAgent('output_artifact_save_failed type=${error.runtimeType}');
      }
    }
    return _toolResult(
      toolCall,
      _commandFeedbackFormatter.format(
        command,
        result,
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        risk: assessment,
        artifact: artifact,
      ),
      isError: result?.exitCode != null && result!.exitCode != 0,
    );
  }
}
