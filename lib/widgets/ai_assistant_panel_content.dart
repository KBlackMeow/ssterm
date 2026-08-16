part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _AiPanelContent — the stateless body of the AI panel (header,
// chat list, input bar, markdown rendering).
//
// Extracted from `ai_assistant_panel.dart` to keep that file under the
// project-wide 1000-line cap.  Stays a private widget because the only
// public surface of this library is [AiAssistantOverlay].
// ───────────────────────────────────────────────────────────────────────────

// ── Panel content ──────────────────────────────────────────────────────────

class _AiPanelContent extends StatelessWidget {
  const _AiPanelContent({
    required this.busy,
    required this.autoExecute,
    this.loopStatus,
    required this.messages,
    required this.textController,
    this.agentInputFocusNode,
    required this.scrollController,
    this.onTranscriptUserScroll,
    required this.onSend,
    required this.onStop,
    this.queuedCount = 0,
    this.onAutoExecuteChanged,
    required this.markdownEnabled,
    this.terminalBackground,
    this.terminalLineHeight,
    this.onWriteProposalDecision,
    this.onEditProposalDecision,
    this.onDangerProposalDecision,
    this.onQuestionProposalDecision,
    this.onQuestionProposalOther,
    this.hasPendingQuestion = false,
    required this.position,
    required this.onClear,
    this.onPositionToggle,
  });

  final bool busy;
  final bool autoExecute;
  final String? loopStatus;
  final List<_ChatMessage> messages;
  final TextEditingController textController;

  /// Focus target for the agent-mode chat `TextField`.  Programmatically
  /// focused when the user taps "Other" on a pending question card —
  /// see `_AiAssistantOverlayState._beginCustomQuestionAnswer`.
  final FocusNode? agentInputFocusNode;
  final ScrollController scrollController;
  final VoidCallback? onTranscriptUserScroll;
  final VoidCallback onSend;

  /// Fires when the user taps the dedicated stop button (shown only while
  /// [busy] and not awaiting a question answer).  Distinct from [onSend],
  /// which always sends — queueing when the agent is engaged.
  final VoidCallback onStop;

  /// Number of user messages waiting in the queue.  `> 0` shows a compact
  /// "queued" chip in the input bar so the user knows their earlier input
  /// hasn't been dropped while the agent is busy.
  final int queuedCount;
  final ValueChanged<bool>? onAutoExecuteChanged;

  /// When `true`, AI replies are rendered with `gpt_markdown` (bold, lists,
  /// code blocks, …).  When `false`, they fall back to a plain `Text` —
  /// fastest, but ` ```bash ``` ` fences appear as literal characters.
  final bool markdownEnabled;

  /// Terminal pane's background color, propagated down so AI-reply code
  /// blocks visually agree with the terminal next to them.  See the
  /// `Theme(...)` wrap in `_buildAgentMessage` for why this matters.
  final Color? terminalBackground;

  /// User's configured terminal line-height — mirrored on markdown body
  /// and on `bodyMedium` (which `gpt_markdown.CodeField` reads from) so
  /// prose + code lines pack at the same density as the terminal pane.
  final double? terminalLineHeight;

  /// Handler the [_WriteProposalCard] calls when the user clicks Apply
  /// or Reject.  Wired to [_AiAssistantOverlayState._decideWriteProposal]
  /// in the state above — kept as a callback (instead of reaching into
  /// the state directly) so the panel content stays a pure stateless
  /// view, the same shape every other interactive control here uses.
  final void Function(
    _WriteProposal proposal, {
    required bool apply,
    String? reason,
  })?
  onWriteProposalDecision;

  /// Handler the [_EditProposalCard] calls when the user clicks Apply
  /// or Reject.  Same pattern as [onWriteProposalDecision] — the panel
  /// stays a pure view, the state machine lives in
  /// [_AiAssistantOverlayState._decideEditProposal].
  final void Function(
    _EditProposal proposal, {
    required bool apply,
    String? reason,
  })?
  onEditProposalDecision;

  /// Handler the [_DangerProposalCard] calls when the user clicks
  /// Approve or Reject.  Same pattern as [onWriteProposalDecision] —
  /// the panel stays a pure view, the state machine lives in
  /// [_AiAssistantOverlayState._decideDangerProposal].
  final void Function(_DangerProposal proposal, {required bool approve})?
  onDangerProposalDecision;

  /// Handler the [_QuestionProposalCard] calls when the user taps a
  /// regular option row (with that option's `label`).  Same pattern as
  /// [onDangerProposalDecision] — the state machine lives in
  /// [_AiAssistantOverlayState._decideQuestionProposal].
  final void Function(_QuestionProposal proposal, {required String answer})?
  onQuestionProposalDecision;

  /// Handler the [_QuestionProposalCard] calls when the user taps
  /// "Other" — does NOT resolve the proposal, just hands focus to the
  /// main input.  See [_AiAssistantOverlayState._beginCustomQuestionAnswer].
  final void Function(_QuestionProposal proposal)? onQuestionProposalOther;

  /// `true` while a [_QuestionProposal] is pending/awaiting a custom
  /// answer — i.e. `_pendingQuestionProposal != null` in the state above.
  ///
  /// The pause-in-place design deliberately keeps [busy] `true` for the
  /// entire time a question card is on screen (including while the user
  /// types a custom "Other" answer), so the loop stays suspended in place.
  /// But the dedicated stop button below must NOT render in that state:
  /// tapping Stop there would call [onStop], marking the question stale
  /// and discarding whatever the user just typed, directly contradicting
  /// the question card's own "send it" instruction. This flag lets the
  /// button distinguish "busy because waiting on the user" from "busy
  /// because the LLM/shell is actively working" without touching the
  /// meaning of [busy] itself.
  final bool hasPendingQuestion;

  /// Current dock side — drives the icon shown on the position toggle
  /// button so it reads "switch to the OTHER side".
  final AiPanelPosition position;

  /// Clears the current Agent conversation and all of its LLM context.
  final VoidCallback onClear;

  /// Tap handler for the position toggle in the mode-switch row.  Null
  /// hides the button (used in tests / hosts that don't persist
  /// layout).
  final VoidCallback? onPositionToggle;

  /// `true` when the input bar should show the red "Stop" button — i.e.
  /// genuinely busy AND not just paused on a pending question.  See
  /// [hasPendingQuestion] doc for why the two must be distinguished.  The
  /// send button itself always stays visible; the stop button is a separate
  /// control that appears only in this state.
  bool get showStopButton => busy && !hasPendingQuestion;

  @override
  Widget build(BuildContext context) {
    // Outer card fill: mirror the terminal pane's `chromeBackground` so the
    // floating card, the 8 px margin strip painted by [_AiAssistantOverlay],
    // and the Scaffold / tab-bar chrome around it all read as ONE contiguous
    // surface.  See the long-form rationale on `panelBg` in the overlay
    // build method: we deliberately avoid `AppColors.popup` here because it
    // derives from `chromeTabSelected` (the base chrome bg lifted ~16 %
    // toward white), which makes the card visibly lighter than the chrome
    // strip the user sees in the same screen region.  The card still reads
    // as a card because PopupSurface keeps its 1 px border + depth shadow.
    //
    // Interior accents (input bar fill, …) keep using `popupColor` so they
    // stay slightly lifted from the card body — that's the demarcation
    // between chat history and the input bar.
    final popupColor =
        AppColors.maybeOf(context)?.popup ?? FrostedGlassStyle.panelFillFrosted;
    final surfaceColor = terminalBackground ?? popupColor;

    return PopupSurface(
      color: surfaceColor,
      // Match SFTP's rounded, frosted-glass card look — same radius constant
      // as `_SftpFloatingChrome` so both panels read as siblings.
      radius: FrostedGlassStyle.panelRadius,
      // backdropBlur intentionally OFF here.
      //
      // The card's fill is now `terminalBackground` (= chromeBackground),
      // the SAME colour the Scaffold, the 8 px strip behind this card,
      // and the terminal pane above all paint with.  Three reasons to
      // keep blur disabled:
      //
      //   1. With wallpaper OFF, `chromeBackground` is fully opaque —
      //      BackdropFilter has nothing useful to blur (the source is
      //      a uniform colour) and just burns GPU on every frame.
      //
      //   2. With wallpaper ON, `chromeBackground` is alpha-blended on
      //      top of the wallpaper, but [WallpaperBackground] already
      //      runs an `ImageFiltered(blur: wallpaperBlur)` so the
      //      wallpaper hitting this layer is ALREADY blurred.  Adding
      //      a second 20 px BackdropFilter blur re-samples the
      //      already-blurred wallpaper and Skia on Metal produces
      //      visible banding / ripple patterns on the panel — the
      //      exact artefact the user reported.  Letting the wallpaper
      //      come through with its single, intentional blur keeps the
      //      panel area visually identical to the terminal area.
      //
      //   3. SFTP's PopupSurface still uses `backdropBlur: 20` because
      //      it intentionally floats on the popup tint (which is more
      //      transparent) and benefits from a visible glass effect.
      //      This card no longer needs that distinction since it
      //      shares the chrome colour outright.
      backdropBlur: 0,
      child: Column(
        children: [
          _AgentHeader(
            position: position,
            onClear: onClear,
            onPositionToggle: onPositionToggle,
          ),
          // Conversation area
          Expanded(
            child: messages.isEmpty
                ? _agentEmptyState(context)
                : NotificationListener<UserScrollNotification>(
                    onNotification: (notification) {
                      if (notification.direction != ScrollDirection.idle) {
                        onTranscriptUserScroll?.call();
                      }
                      return false;
                    },
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        itemCount:
                            messages.length + (loopStatus != null ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (loopStatus != null && i == messages.length) {
                            return _loopStatusIndicator(context, loopStatus!);
                          }
                          return _buildAgentMessage(ctx, messages[i]);
                        },
                      ),
                    ),
                  ),
          ),
          // Input bar — text field + auto-execute toggle + send/stop button
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              color: popupColor,
              border: Border(
                top: BorderSide(
                  color:
                      (AppColors.maybeOf(context)?.foregroundDim ??
                              _kFgInactive)
                          .withValues(alpha: 0.15),
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Container(
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF2472C8).withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: textController,
                            focusNode: agentInputFocusNode,
                            textInputAction: TextInputAction.send,
                            style: TextStyle(
                              color:
                                  AppColors.maybeOf(context)?.foreground ??
                                  _kFgActive,
                              fontSize: 13,
                              height: 1.2,
                              fontFamily: _agentBodyFontFamily,
                              fontFamilyFallback: _agentBodyFontFallback,
                              fontWeight: FontWeight.w400,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Ask AI anything…',
                              hintStyle: TextStyle(
                                color: const Color(0xFF8E8E8E),
                                fontSize: 13,
                                fontFamily: _agentBodyFontFamily,
                                fontFamilyFallback: _agentBodyFontFallback,
                                fontWeight: FontWeight.w400,
                              ),
                              border: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.fromLTRB(12, 0, 8, 0),
                              isDense: true,
                            ),
                            onSubmitted: (_) => onSend(),
                          ),
                        ),
                        // Compact auto-execute chip inside the input field row
                        Tooltip(
                          message: autoExecute
                              ? '自动模式：仅危险命令需要确认'
                              : '审慎模式：普通命令直接执行，警告和危险命令需要确认',
                          child: GestureDetector(
                            onTap: () =>
                                onAutoExecuteChanged?.call(!autoExecute),
                            child: Container(
                              height: 20,
                              margin: const EdgeInsets.only(right: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              decoration: BoxDecoration(
                                color: autoExecute
                                    ? const Color(
                                        0xFF2E7D32,
                                      ).withValues(alpha: 0.3)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: autoExecute
                                      ? const Color(
                                          0xFF2E7D32,
                                        ).withValues(alpha: 0.5)
                                      : dimColor(
                                          context,
                                        ).withValues(alpha: 0.25),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.auto_awesome,
                                    size: 10,
                                    color: autoExecute
                                        ? const Color(0xFF2EE767)
                                        : dimColor(context),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Auto',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: autoExecute
                                          ? const Color(0xFF2E7D32)
                                          : dimColor(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // Queued-input chip — how many typed messages are
                        // waiting for the current turn to finish.
                        if (queuedCount > 0)
                          Container(
                            height: 20,
                            margin: const EdgeInsets.only(right: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF2472C8,
                              ).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.schedule,
                                  size: 10,
                                  color: Color(0xFF2472C8),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '$queuedCount',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF2472C8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // Dedicated stop button — only while genuinely busy.
                        // Cancels the current turn (and completes any dangling
                        // tool call) without discarding queued input.
                        if (showStopButton)
                          GestureDetector(
                            onTap: onStop,
                            child: Container(
                              width: 26,
                              height: 26,
                              margin: const EdgeInsets.only(right: 4),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF6E67),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(
                                Icons.stop_rounded,
                                size: 13,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        // Send button — always available.  Sends now, or queues
                        // the message when the agent is engaged.
                        GestureDetector(
                          onTap: onSend,
                          child: Container(
                            width: 26,
                            height: 26,
                            margin: const EdgeInsets.only(right: 4),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2472C8),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(
                              Icons.send_rounded,
                              size: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color dimColor(BuildContext context) =>
      (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(
        alpha: 0.6,
      );

  Widget _loopStatusIndicator(BuildContext context, String status) {
    final dim = dimColor(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status,
              style: TextStyle(
                color: dim,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _agentEmptyState(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.5);
    final dimmer = dim.withValues(alpha: 0.6);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 28, color: dim),
          const SizedBox(height: 12),
          Text(
            'What can the Agent\nhelp you with today?',
            textAlign: TextAlign.center,
            style: TextStyle(color: dim, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          Text(
            'Tip: type /help to see slash-commands',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: dimmer,
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ],
      ),
    );
  }

  /// Renders the AI reply with `gpt_markdown` inside a scoped `Theme`
  /// override so the package's hardcoded `CodeField` widget picks up:
  ///   • our 13 px font (instead of the Material `bodyMedium = 14 px` it
  ///     reads from `theme.textTheme.bodyMedium` via the `Material` widget
  ///     wrapper around the code block — see Flutter's `material.dart:476`,
  ///     which wraps the child in `AnimatedDefaultTextStyle(style:
  ///     widget.textStyle ?? Theme.of(context).textTheme.bodyMedium!)`,
  ///     stomping any outer `DefaultTextStyle.merge` we set.  The ONLY way
  ///     to influence it is to override `theme.textTheme.bodyMedium` itself.
  ///   • the active terminal pane's background color (instead of the
  ///     Material default `colorScheme.onInverseSurface`, which is a near-
  ///     white pill on a dark UI — visually disconnected from the dark
  ///     terminal sitting next to the chat panel).  CodeField reads the
  ///     bg from `Theme.of(context).colorScheme.onInverseSurface`, so we
  ///     swap that one slot in the colorScheme.
  Widget _buildMarkdown(BuildContext context, String text, Color fg) {
    final base = Theme.of(context);
    // Fall back to a neutral-dark surface when there's no active pane
    // (settings tab, transient state, …).  Slight transparency lets the
    // chat panel's own frosted bg bleed through, which softens the edge.
    final codeBg = terminalBackground ?? Colors.black.withValues(alpha: 0.35);

    // Line-height is mirrored from the user's terminal setting so the AI
    // chat reads at the SAME density as the terminal pane next to it.  The
    // previous fixed value of 1.5 was visibly airier than the terminal
    // (which defaults to 1.2 in `TerminalSettings`), making code blocks
    // look gappy compared to identical text shown in the terminal itself.
    //
    // We apply the same height in TWO places:
    //   • `bodyMedium` — `gpt_markdown.CodeField` reads font metrics from
    //     this textTheme slot, so this is what controls fenced ```code```
    //     line spacing.
    //   • outer `GptMarkdown.style` — controls inline / prose lines.
    final lh = terminalLineHeight ?? 1.2;

    final bodyMedium = (base.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          fontSize: 13,
          fontFamily: _agentBodyFontFamily,
          fontFamilyFallback: _agentBodyFontFallback,
          fontWeight: FontWeight.w400,
          color: fg,
          height: lh,
        );
    return Theme(
      data: base.copyWith(
        textTheme: base.textTheme.copyWith(bodyMedium: bodyMedium),
        colorScheme: base.colorScheme.copyWith(onInverseSurface: codeBg),
      ),
      child: GptMarkdown(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 13,
          height: lh,
          fontFamily: _agentBodyFontFamily,
          fontFamilyFallback: _agentBodyFontFallback,
          fontWeight: FontWeight.w400,
        ),
        // We override fenced-code-block rendering for two reasons:
        //   1. `gpt_markdown` 1.1.7's `CodeBlockMd` regex captures the
        //      `\n` BEFORE the closing fence into the body string, then
        //      only strips the literal backticks — leaving a phantom
        //      blank line at the bottom of every code block.  We trim
        //      trailing whitespace ourselves to fix this.
        //   2. The default `CodeField` widget uses `EdgeInsets.all(16)`
        //      padding, which is too airy for short shell commands.  We
        //      use tighter padding so single-line commands like `ls -al`
        //      no longer look stranded inside a tall card.
        codeBuilder: (ctx, name, code, closed) => _AiCodeBlock(
          name: name,
          code: code,
          background: codeBg,
          foreground: fg,
          lineHeight: lh,
        ),
      ),
    );
  }

  Widget _buildAgentMessage(BuildContext context, _ChatMessage msg) {
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.6);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    if (msg.isSystem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _CommandResultCard(
          command: msg.commandRun ?? '',
          output: msg.text,
          purpose: msg.commandPurpose,
          exitCode: msg.commandExitCode,
          lastThreeLines: msg.commandLastThreeLines ?? const [],
          running: msg.commandRunning == true,
          risk: msg.commandRisk,
        ),
      );
    }

    // File-write proposal: distinct Apply/Reject card with diff preview.
    // Owns its own surface to make it visually unmissable — a write is
    // an irreversible operation, so it must NOT look like a regular
    // notice / system result.
    //
    // If [onWriteProposalDecision] is null the card still renders, but
    // the buttons are no-ops — same defensive shape as the rest of the
    // panel callbacks (the host can always pass null when in a state
    // where decisions don't make sense, e.g. mid-tear-down).
    final proposal = msg.writeProposal;
    if (proposal != null) {
      final decide = onWriteProposalDecision;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 32),
        child: _WriteProposalCard(
          proposal: proposal,
          onApply: decide == null ? () {} : () => decide(proposal, apply: true),
          onReject: decide == null
              ? ({String? reason}) {}
              : ({String? reason}) =>
                    decide(proposal, apply: false, reason: reason),
        ),
      );
    }

    // File-edit proposal: same Apply/Reject shell as the write-proposal
    // card, but the body renders a line-level diff instead of a flat
    // content preview — see `_EditProposalCard`.
    final editProposal = msg.editProposal;
    if (editProposal != null) {
      final decide = onEditProposalDecision;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 32),
        child: _EditProposalCard(
          proposal: editProposal,
          onApply: decide == null
              ? () {}
              : () => decide(editProposal, apply: true),
          onReject: decide == null
              ? ({String? reason}) {}
              : ({String? reason}) =>
                    decide(editProposal, apply: false, reason: reason),
        ),
      );
    }

    // Dangerous-command proposal: same Apply/Reject pattern as the
    // file-write card, distinct visual hierarchy.  Card-level null
    // callback collapses to a no-op for the same defensive reason as
    // the write-proposal handler above.
    final danger = msg.dangerProposal;
    if (danger != null) {
      final decide = onDangerProposalDecision;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 32),
        child: _DangerProposalCard(
          proposal: danger,
          onApprove: decide == null
              ? () {}
              : () => decide(danger, approve: true),
          onReject: decide == null
              ? () {}
              : () => decide(danger, approve: false),
        ),
      );
    }

    // Ask-user question: multiple-choice card, structured sibling of
    // the plain `[ASK_USER]` free-text prompt.  Same null-callback
    // no-op fallback as the two cards above.
    final question = msg.questionProposal;
    if (question != null) {
      final decide = onQuestionProposalDecision;
      final other = onQuestionProposalOther;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 32),
        child: _QuestionProposalCard(
          proposal: question,
          onOptionSelected: decide == null
              ? (_) {}
              : (label) => decide(question, answer: label),
          onOther: other == null ? () {} : () => other(question),
        ),
      );
    }

    // MCP tool call result: expandable card showing tool name, server,
    // and content blocks.
    final mcpResult = msg.mcpResultData;
    if (mcpResult != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 32),
        child: _McpResultCard(data: mcpResult),
      );
    }

    final toolCalls = msg.toolCallData;
    if (toolCalls != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _ToolCallCard(data: toolCalls),
      );
    }

    // `== true` instead of plain truthy check — `isNotice` is `bool?` so
    // legacy hot-reloaded objects (where the field didn't exist when they
    // were constructed) safely compare to false instead of throwing on a
    // null getter result.  See `_ChatMessage.isNotice` doc for context.
    if (msg.isNotice == true) {
      // Subdued info card — distinct from AI replies so users immediately
      // recognise this as a client-side notice (slash-command output)
      // rather than thinking the AI answered them.
      final noticeFg = dim.withValues(alpha: 0.85);
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: surface.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: dim.withValues(alpha: 0.15), width: 0.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 14, color: noticeFg),
              const SizedBox(width: 8),
              Expanded(child: _buildMarkdown(context, msg.text, noticeFg)),
            ],
          ),
        ),
      );
    }

    if (msg.isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF2472C8).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                Icons.person_outline,
                size: 14,
                color: const Color(0xFF2472C8),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                msg.text,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  height: 1.5,
                  fontFamily: _agentBodyFontFamily,
                  fontFamilyFallback: _agentBodyFontFallback,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.auto_awesome, size: 14, color: _kAccent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (msg.error != null)
                  Text(
                    msg.error!,
                    style: const TextStyle(
                      color: Color(0xFFFF6E67),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  )
                else ...[
                  if (msg.reasoning != null)
                    _ReasoningSection(
                      reasoning: msg.reasoning!,
                      tokenCount: msg.reasoningTokenCount,
                      isExactTokenCount:
                          msg.hasExactReasoningTokenCount == true,
                    ),
                  if (markdownEnabled && msg.text.isNotEmpty)
                    _buildMarkdown(context, msg.text, fg)
                  else
                    Text(
                      msg.text,
                      style: TextStyle(color: fg, fontSize: 13, height: 1.5),
                    ),
                ],
                // Proposed commands no longer render here at all — every
                // command (dangerous or not) now surfaces as its own
                // `_DangerProposal` card (see ai_assistant_panel_loop.dart's
                // per-command confirmation gate), inserted as a separate
                // message right after this one.
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Expandable card showing the model's requested tool calls before dispatch.
class _ToolCallCard extends StatelessWidget {
  final _ToolCallData data;
  const _ToolCallCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final fg =
        AppColors.maybeOf(context)?.foreground ?? const Color(0xFFD4D4D4);
    final dim =
        (AppColors.maybeOf(context)?.foregroundDim ?? const Color(0xFF8E8E8E))
            .withValues(alpha: 0.7);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    return Material(
      color: surface.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.blue.withValues(alpha: 0.22)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        dense: true,
        leading: Icon(
          Icons.handyman_outlined,
          size: 16,
          color: Colors.blue.shade300,
        ),
        title: Text(
          data.summary,
          textAlign: TextAlign.left,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
        children: [
          for (final call in data.calls)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    call.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    'id: ${call.id}',
                    style: TextStyle(
                      fontSize: 10,
                      color: dim,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 5),
                  SelectableText(
                    data.formattedArgumentsFor(call),
                    style: TextStyle(
                      fontSize: 11,
                      color: fg,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Simple card rendering an MCP tool call result.
class _McpResultCard extends StatefulWidget {
  final _McpResultData data;
  const _McpResultCard({required this.data});

  @override
  State<_McpResultCard> createState() => _McpResultCardState();
}

class _McpResultCardState extends State<_McpResultCard> {
  static const _kCollapsedLines = 4;

  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        AppColors.maybeOf(context)?.foreground ?? const Color(0xFFD4D4D4);
    final dim =
        (AppColors.maybeOf(context)?.foregroundDim ?? const Color(0xFF8E8E8E))
            .withValues(alpha: 0.6);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    final result = widget.data.result;
    final isError = result.isError;
    final lines = _contentLines(result.content);
    final overflow = !_expanded && lines.length > _kCollapsedLines;
    final preview = overflow
        ? lines.sublist(0, _kCollapsedLines).join('\n')
        : lines.join('\n');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError
              ? Colors.red.withValues(alpha: 0.3)
              : Colors.green.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.handyman_outlined,
                size: 14,
                color: isError ? Colors.red.shade300 : Colors.green.shade300,
              ),
              const SizedBox(width: 6),
              Text(
                'MCP: ${widget.data.serverId}/${widget.data.toolName}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 8),
            if (_expanded)
              for (final block in result.content)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _buildContentBlock(block, dim, fg),
                )
            else
              SelectableText(
                preview,
                style: TextStyle(
                  fontSize: 12,
                  color: fg,
                  fontFamily: 'monospace',
                ),
              ),
            if (overflow) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(() => _expanded = true),
                child: Text(
                  '+ ${lines.length - _kCollapsedLines} more lines',
                  style: TextStyle(
                    color: dim,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    decoration: TextDecoration.underline,
                    decorationColor: dim.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
            if (_expanded && lines.length > _kCollapsedLines) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(() => _expanded = false),
                child: Text(
                  'Collapse',
                  style: TextStyle(
                    color: dim,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    decoration: TextDecoration.underline,
                    decorationColor: dim.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  List<String> _contentLines(Iterable<McpContentBlock> blocks) {
    final lines = <String>[];
    for (final block in blocks) {
      if (block.type == 'text') {
        lines.addAll((block.text ?? '').split('\n'));
      } else {
        lines.add(_contentLabel(block));
      }
    }
    return lines;
  }

  String _contentLabel(McpContentBlock block) {
    switch (block.type) {
      case 'image':
        return '[image: ${block.mimeType ?? "unknown"}]';
      case 'resource':
        return '[resource: ${block.uri ?? "unknown"}]';
      default:
        return '[${block.type} content]';
    }
  }

  Widget _buildContentBlock(McpContentBlock block, Color dim, Color fg) {
    switch (block.type) {
      case 'text':
        return SelectableText(
          block.text ?? '',
          style: TextStyle(fontSize: 12, color: fg, fontFamily: 'monospace'),
        );
      case 'image':
        return Text(
          _contentLabel(block),
          style: TextStyle(
            fontSize: 11,
            color: dim,
            fontStyle: FontStyle.italic,
          ),
        );
      case 'resource':
        return Text(
          _contentLabel(block),
          style: TextStyle(
            fontSize: 11,
            color: dim,
            fontStyle: FontStyle.italic,
          ),
        );
      default:
        return Text(
          _contentLabel(block),
          style: TextStyle(
            fontSize: 11,
            color: dim,
            fontStyle: FontStyle.italic,
          ),
        );
    }
  }
}
