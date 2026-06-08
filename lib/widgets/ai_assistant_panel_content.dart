part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _AiPanelContent — the stateless body of the AI panel (mode switch,
// chat list, input bar, markdown rendering).
//
// Extracted from `ai_assistant_panel.dart` to keep that file under the
// project-wide 1000-line cap.  Stays a private widget because the only
// public surface of this library is [AiAssistantOverlay].
// ───────────────────────────────────────────────────────────────────────────

// ── Panel content ──────────────────────────────────────────────────────────

class _AiPanelContent extends StatelessWidget {
  const _AiPanelContent({
    required this.mode,
    required this.busy,
    required this.autoExecute,
    this.loopStatus,
    required this.messages,
    required this.textController,
    required this.scrollController,
    required this.onSend,
    required this.onCancel,
    this.onAutoExecuteChanged,
    required this.onInsert,
    required this.onSendToTerminal,
    required this.onRunManualCommand,
    required this.onModeChanged,
    this.shellIntegrationActive,
    required this.markdownEnabled,
    this.terminalBackground,
    this.terminalLineHeight,
    this.onWriteProposalDecision,
  });

  final AiPanelMode mode;
  final bool busy;
  final bool autoExecute;
  final String? loopStatus;
  final List<_ChatMessage> messages;
  final TextEditingController textController;
  final ScrollController scrollController;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final ValueChanged<bool>? onAutoExecuteChanged;
  final ValueChanged<String>? onInsert;

  /// Command-mode "send & forget": user typed a literal command and pressed
  /// Enter — bytes go straight to the active terminal pane, NOT through the
  /// agent.  This is intentionally separate from the agent execution path.
  final ValueChanged<String>? onSendToTerminal;

  /// Agent-mode "Exec" button on an AI message card.  Routes through the
  /// same OSC 133 capture pipeline used by the auto-execute loop, so the
  /// agent always sees a consistent view of the world regardless of whether
  /// the user clicked the button manually or `auto-execute` was on.
  final Future<void> Function(String cmd)? onRunManualCommand;

  final ValueChanged<AiPanelMode> onModeChanged;

  /// `true` → OSC 133 shell integration is active on the current pane.
  /// `false` → echo-sentinel fallback path will be used.  `null` → no pane.
  final bool? shellIntegrationActive;

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
  final void Function(_WriteProposal proposal,
      {required bool apply, String? reason})? onWriteProposalDecision;

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
          _ModeSwitch(
            mode: mode,
            onChanged: onModeChanged,
            shellIntegrationActive: shellIntegrationActive,
          ),
          // Command mode: multi-line input fills available space
          if (mode == AiPanelMode.command)
            Expanded(
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                    child: TextField(
                      controller: textController,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: TextStyle(
                        color: AppColors.maybeOf(context)?.foreground ?? _kFgActive,
                        fontSize: 13,
                        fontFamily: 'JetBrainsMono',
                        height: 1.4,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Type your command (multi-line supported)…',
                        hintStyle: TextStyle(
                          color: (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
                              .withValues(alpha: 0.5),
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        isDense: true,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: GestureDetector(
                      onTap: onSend,
                      child: Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2472C8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.send_rounded, size: 15, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Agent mode: chat layout
          if (mode == AiPanelMode.agent) ...[
            // Conversation area
            Expanded(
              child: messages.isEmpty
                  ? _agentEmptyState(context)
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: messages.length + (loopStatus != null ? 1 : 0),
                      itemBuilder: (ctx, i) {
                        if (loopStatus != null && i == messages.length) {
                          return _loopStatusIndicator(context, loopStatus!);
                        }
                        return _buildAgentMessage(ctx, messages[i]);
                      },
                    ),
            ),
            // Input bar — text field + auto-execute toggle + send/stop button
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                color: popupColor,
                border: Border(
                  top: BorderSide(
                    color: (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
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
                              textInputAction: TextInputAction.send,
                              style: TextStyle(
                                color: AppColors.maybeOf(context)?.foreground ?? _kFgActive,
                                fontSize: 13,
                                height: 1.2,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'Ask AI anything…',
                                hintStyle: TextStyle(
                                  color: Color(0xFF8E8E8E),
                                  fontSize: 13,
                                ),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.fromLTRB(12, 0, 8, 0),
                                isDense: true,
                              ),
                              onSubmitted: (_) => onSend(),
                            ),
                          ),
                          // Compact auto-execute chip inside the input field row
                          GestureDetector(
                            onTap: () => onAutoExecuteChanged?.call(!autoExecute),
                            child: Container(
                              height: 20,
                              margin: const EdgeInsets.only(right: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                color: autoExecute
                                    ? const Color(0xFF2E7D32).withValues(alpha: 0.3)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: autoExecute
                                      ? const Color(0xFF2E7D32).withValues(alpha: 0.5)
                                      : dimColor(context).withValues(alpha: 0.25),
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
                          GestureDetector(
                            onTap: busy ? onCancel : onSend,
                            child: Container(
                              width: 26,
                              height: 26,
                              margin: const EdgeInsets.only(right: 4),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: busy ? const Color(0xFFFF6E67) : const Color(0xFF2472C8),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                busy ? Icons.stop_rounded : Icons.send_rounded,
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
        ],
      ),
    );
  }

  Color dimColor(BuildContext context) =>
      (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);

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
              style: TextStyle(color: dim, fontSize: 11, fontStyle: FontStyle.italic),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _agentEmptyState(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.5);
    final dimmer = dim.withValues(alpha: 0.6);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 28, color: dim),
          const SizedBox(height: 12),
          Text(
            'What can the terminal AI agent\nhelp you with today?',
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
          fontFamily: 'JetBrainsMono',
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
        style: TextStyle(color: fg, fontSize: 13, height: lh),
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
    final dim =
        (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);
    final surface = AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    if (msg.isSystem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 32),
        child: _CommandResultCard(
          command: msg.commandRun ?? '',
          output: msg.text,
          exitCode: msg.commandExitCode,
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
          onApply: decide == null
              ? () {}
              : () => decide(proposal, apply: true),
          onReject: decide == null
              ? ({String? reason}) {}
              : ({String? reason}) =>
                  decide(proposal, apply: false, reason: reason),
        ),
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
              Expanded(
                child: _buildMarkdown(context, msg.text, noticeFg),
              ),
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
              child: Icon(Icons.person_outline, size: 14, color: const Color(0xFF2472C8)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                msg.text,
                style: TextStyle(color: fg, fontSize: 13, height: 1.5),
              ),
            ),
          ],
        ),
      );
    }

    final cmds = msg.commands ?? <String>[];
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
                  Text(msg.error!, style: const TextStyle(color: Color(0xFFFF6E67), fontSize: 13, height: 1.5))
                else ...[
                  if (msg.reasoning != null)
                    _ReasoningSection(reasoning: msg.reasoning!),
                  if (markdownEnabled && msg.text.isNotEmpty)
                    _buildMarkdown(context, msg.text, fg)
                  else
                    Text(msg.text,
                        style: TextStyle(color: fg, fontSize: 13, height: 1.5)),
                ],
                // Per-command UI rules:
                //   markdown ON  + auto-execute ON  → skip entirely; the
                //       command is already shown by GptMarkdown's code
                //       block above and Layer 3 (the result card) confirms
                //       what ran.
                //   markdown ON  + auto-execute OFF → render only a compact
                //       Exec button (no command text — markdown already
                //       shows it).
                //   markdown OFF + auto-execute ON  → keep the monospaced
                //       preview box so users can spot what the loop is
                //       running, but no button.
                //   markdown OFF + auto-execute OFF → preview box + Exec
                //       button, the original layout.
                if (cmds.isNotEmpty &&
                    onRunManualCommand != null &&
                    !(markdownEnabled && autoExecute)) ...[
                  const SizedBox(height: 8),
                  for (var i = 0; i < cmds.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    if (markdownEnabled)
                      // Compact button-only row — no preview, the markdown
                      // code block above is the source of truth.
                      Align(
                        alignment: Alignment.centerLeft,
                        child: GestureDetector(
                          onTap: () => onRunManualCommand?.call(cmds[i]),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2E7D32),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.play_arrow,
                                    size: 12, color: Colors.white),
                                SizedBox(width: 4),
                                Text('Exec',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: dim.withValues(alpha: 0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cmds[i],
                              style: TextStyle(
                                color: fg,
                                fontSize: 13,
                                fontFamily: 'JetBrainsMono',
                                height: 1.4,
                              ),
                            ),
                            if (!autoExecute) ...[
                              const SizedBox(height: 8),
                              GestureDetector(
                                onTap: () => onRunManualCommand?.call(cmds[i]),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2E7D32),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.play_arrow,
                                          size: 12, color: Colors.white),
                                      SizedBox(width: 4),
                                      Text('Exec',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
