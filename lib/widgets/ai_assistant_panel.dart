import 'dart:async';
import 'dart:convert';
import 'dart:io' show stdout, HttpException, Platform, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gpt_markdown/gpt_markdown.dart';

import '../io/output_pipe.dart' show CommandResult;
import '../models/agent_config.dart';
import '../models/mcp_server_config.dart';
import '../models/skill.dart';
import '../services/command_feedback_formatter.dart';
import '../services/background_command_executor.dart'
    show CommandExecutionUpdateListener, CommandSilenceDecider;
import '../services/agent_context_budget.dart';
import '../services/agent_stream_client_session.dart';
import '../services/command_safety.dart';
import '../services/command_risk.dart';
import '../services/conversation_compactor.dart';
import '../services/llm_service.dart';
import '../services/agent_tool_contract.dart';
import '../services/file_write_service.dart';
import '../services/file_edit_service.dart';
import '../services/mcp_service.dart';
import '../utils/line_diff.dart';
import '../services/session_context.dart';
import '../services/skill_service.dart';
import '../services/web_search_service.dart';
import '../services/tool_call_display_formatter.dart';
import 'frosted_glass.dart';

// ───────────────────────────────────────────────────────────────────────────
// Part files — split out to keep this file under the project-wide 1000-line
// cap.  All five are library-private extensions / widgets / models that have
// no use outside this library; the only public surface is
// [AiAssistantOverlay] below.
// ───────────────────────────────────────────────────────────────────────────

part 'ai_assistant_panel_models.dart';
part 'ai_assistant_panel_widgets.dart';
part 'ai_assistant_panel_content.dart';
part 'ai_assistant_panel_write_card.dart';
part 'ai_assistant_panel_danger_card.dart';
part 'ai_assistant_panel_question_card.dart';
part 'ai_assistant_panel_edit_card.dart';
part 'ai_assistant_panel_tooling.dart';
part 'ai_assistant_panel_loop.dart';

const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);

String get _agentBodyFontFamily =>
    Platform.isWindows ? 'Consolas' : 'JetBrainsMono';

List<String> get _agentBodyFontFallback => Platform.isWindows
    ? const ['Microsoft YaHei']
    : const ['Noto Sans Mono CJK SC', 'sans-serif'];

/// Minimum side (height when docked at bottom, width when docked right).
///
/// Sized to keep the chat list usable in both orientations:
///   • At 240 px tall the bottom panel shows ~6 chat lines + the input bar.
///   • At 240 px wide the right panel keeps the markdown code blocks from
///     wrapping every shell command across multiple lines.
const _kPanelMinExtent = 240.0;
const _kPanelDefaultFraction = 0.42; // 0.35 + 20%
const _kPanelMaxFraction = 0.6;

/// Outer gap between the AI panel card and the surrounding chrome — matches
/// `_kSftpPanelMargin` in `ssh_session_view.dart` so the two side-by-side
/// panels (SFTP card + AI card) share the same floating "card" rhythm.
const _kAiPanelMargin = 8.0;

// ── Agent-loop tunables ────────────────────────────────────────────────────
// Top-level (instead of static members on `_AiAssistantOverlayState`) so the
// `_AiAgentLoopExt` extension in `ai_assistant_panel_loop.dart` can read them
// directly — extension members can't reach `_AiAssistantOverlayState.<static>`
// without a class qualifier.  Library-private (`_`-prefixed) so nothing
// outside this library can read them.

/// Max conversation turns / loop iterations before we summarise old ones.
const _recentHistoryItems = 16;
const _historyItemFallbackLimit = 80;

/// Number of head messages kept across truncation — typically the user's
/// initial task + the agent's first response.  Pinning these prevents the
/// agent from "forgetting its goal" when long auto-execute chains push the
/// conversation past [_maxHistoryTurns].
const _kPinnedHeadMessages = 2;

const _commandFeedbackFormatter = CommandFeedbackFormatter();

/// Dock side for the Agent panel. Mirrors [SftpPanelPosition] so both panels
/// use the same orientation and persistence model.
enum AiPanelPosition { bottom, right }

class AiAssistantOverlay extends StatefulWidget {
  const AiAssistantOverlay({
    super.key,
    required this.child,
    required this.visible,
    this.onExecuteAsync,
    this.agentConfig,
    this.terminalBackground,
    this.terminalLineHeight,
    this.fileSystemAdapter,
    this.executionEnvironment,
    this.initialPosition = AiPanelPosition.right,
    this.initialSize,
    this.onLayoutChanged,
  });

  final Widget child;
  final bool visible;

  /// Execute a command in the Agent's background process and return its
  /// captured stdout/stderr and exit code.
  final Future<CommandResult?> Function(
    String cmd, {
    bool Function()? isCancelled,
    CommandExecutionUpdateListener? onUpdate,
    CommandSilenceDecider? onSilence,
  })?
  onExecuteAsync;

  /// Agent provider configuration.
  final AgentConfig? agentConfig;

  /// The active terminal pane's background color, used as the surface fill
  /// for ```bash ``` code blocks rendered inside AI replies so the chat
  /// transcript visually matches the terminal it sits next to.  Null
  /// falls back to a neutral subtle dark surface.
  final Color? terminalBackground;

  /// The user's configured terminal line-height (`TerminalSettings.lineHeight`,
  /// default 1.2).  We mirror the same value in markdown-rendered AI replies
  /// so prose AND code blocks pack their lines at the same density as the
  /// terminal pane next door — a fixed `height: 1.5` here was visibly airier
  /// than the terminal at 1.2.  Null falls back to 1.2.
  final double? terminalLineHeight;

  /// File-system backend used by the agent's `[WRITE_FILE_BEGIN]` /
  /// `[WRITE_FILE_END]` tool to materialise proposed file writes.
  ///
  ///   • LOCAL tabs pass [LocalFileSystemAdapter] — writes land on
  ///     the host running ssterm via `dart:io` with atomic temp+rename.
  ///   • SSH tabs pass [SftpFileSystemAdapter] wrapping `tab.sftp` —
  ///     writes go over the existing SFTP channel.
  ///   • Tabs without a usable filesystem (Settings, connecting, …)
  ///     pass null; the panel intercepts the marker and replies with a
  ///     `[File write failed] reason: notSupported` envelope instead.
  ///
  /// Reconstructed by the host on every build so a tab switch
  /// immediately swaps the adapter the next Apply click will use.
  final FileSystemAdapter? fileSystemAdapter;

  /// Per-tab command environment supplied to the first agent turn. This is
  /// distinct from the OS that runs the Flutter UI (for example, WSL on a
  /// Windows host).
  final String? executionEnvironment;

  /// Initial dock side — restored from [AppConfig.agentPosition] on app
  /// launch.  The user can flip this from the in-panel toggle, which
  /// fires [onLayoutChanged] so the new value persists.
  final AiPanelPosition initialPosition;

  /// Initial pixel extent of the panel along its dock axis (height when
  /// docked at the bottom, width when docked at the right).  Null falls
  /// back to [_kPanelDefaultFraction] of the available extent.
  final double? initialSize;

  /// Fires whenever the user drags the resize handle OR flips the dock
  /// side via the toggle button.  Hosts wire this to
  /// [AppConfig.agentPosition] / [AppConfig.agentSize] + `save()` so the
  /// layout sticks across launches.
  final void Function(AiPanelPosition position, double? size)? onLayoutChanged;
  @override
  State<AiAssistantOverlay> createState() => _AiAssistantOverlayState();
}

class _AiAssistantOverlayState extends State<AiAssistantOverlay> {
  // Dock side + custom drag-resized extent.  Initialised in [initState]
  // from the host's persisted values; subsequent mutations notify the
  // host via `widget.onLayoutChanged` so the new value rides into config.
  late AiPanelPosition _position;
  double? _customPanelSize;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
    _customPanelSize = widget.initialSize;
  }

  final _agentController = TextEditingController();
  final _scrollController = ScrollController();
  final _agentMessages = <_ChatMessage>[];
  var _agentBusy = false;
  var _autoExecute = false;
  String? _agentLoopStatus;
  void Function()? _cancelStream;
  AgentStreamClientSession? _streamSession;
  int? _streamSessionGeneration;
  int? _streamSessionPausedGeneration;
  int _generation = 0;

  /// The `_QuestionProposal` currently awaiting an answer (option tap OR
  /// custom "Other" text via the main chat input), or null when no
  /// `ask_user_question` card is pending.  Set when the card appears
  /// (see `ai_assistant_panel_loop.dart`'s `ask_user_question`
  /// interception) and cleared the moment it's answered or goes stale
  /// (see `_decideQuestionProposal` in `ai_assistant_panel_tooling.dart`).
  _QuestionProposal? _pendingQuestionProposal;
  _DangerProposal? _pendingDangerProposal;

  /// Focus target for the agent-mode chat `TextField`, used ONLY to
  /// hand focus back to the input when the user taps "Other" on a
  /// pending question card — see `_beginCustomQuestionAnswer`.
  final _agentInputFocusNode = FocusNode();

  /// Monotonic counter for the user-message-driven agent turns within
  /// this process.  Used as the `t=N` prefix on every `[agent] iter=…`
  /// log line so consecutive turns are visually distinguishable in
  /// `flutter run` output (each new user message bumps the counter,
  /// while each LLM iteration WITHIN that turn shares it).  Without
  /// this you can't tell whether `iter=1 start history=5` is the start
  /// of a new turn or a retry of the previous one.
  int _agentTurnSeq = 0;

  // Conversation history for agent mode (preserved across messages).
  final _conversationHistory = AgentConversationHistory();

  TextEditingController get _textController => _agentController;

  List<_ChatMessage> get _messages => _agentMessages;

  @override
  void dispose() {
    _generation++;
    _cancelStream?.call();
    _cancelPendingAgentDecisions();
    _streamSession?.close(force: true);
    _streamSession = null;
    _agentController.dispose();
    _scrollController.dispose();
    _agentInputFocusNode.dispose();
    super.dispose();
  }

  void _cancelAgent() {
    _generation++;
    _cancelStream?.call();
    _cancelStream = null;
    _cancelPendingAgentDecisions();
    _streamSession?.close(force: true);
    _streamSession = null;
    _streamSessionGeneration = null;
    _streamSessionPausedGeneration = null;
    setState(() {
      _agentBusy = false;
      _agentLoopStatus = null;
      // A pending ask_user_question card's `await` would otherwise
      // leak forever once the loop that owns it has been abandoned —
      // force it to its stale terminal state here, same idea as the
      // lazy staleness check `_decideQuestionProposal` runs when a
      // card IS clicked after the fact, just done eagerly on cancel.
      _pendingQuestionProposal = null;
    });
  }

  void _cancelPendingAgentDecisions() {
    final pendingQuestion = _pendingQuestionProposal;
    if (pendingQuestion != null && !pendingQuestion.decision.isCompleted) {
      pendingQuestion.state = _QuestionProposalState.stale;
      pendingQuestion.decision.complete(null);
    }
    _pendingQuestionProposal = null;

    final pendingDanger = _pendingDangerProposal;
    if (pendingDanger != null && !pendingDanger.decision.isCompleted) {
      pendingDanger.state = _DangerProposalState.rejected;
      pendingDanger.decision.complete(false);
    }
    _pendingDangerProposal = null;
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // If a question-proposal card is waiting on an answer (option tap
    // OR the "Other" custom-text path), whatever the user just typed
    // IS that answer — route it to the pending proposal instead of
    // falling through to slash commands or a brand-new agent turn.
    // `_pendingQuestionProposal` is only ever non-null while a card is
    // genuinely pending or awaiting custom text (see
    // `_decideQuestionProposal`, which clears it the moment an answer
    // is recorded), so no extra state check is needed here.
    final pendingQuestion = _pendingQuestionProposal;
    if (pendingQuestion != null) {
      _textController.clear();
      _decideQuestionProposal(pendingQuestion, answer: text);
      _scrollToBottom();
      return;
    }

    // Intercept slash-commands BEFORE the LLM / shell receives anything.
    // Returning true means "fully handled — do not fall through to send".
    if (_handleSlashCommand(text)) return;

    // If busy, cancel in-flight and start fresh.
    if (_agentBusy) _cancelAgent();

    setState(() {
      _messages.add(_ChatMessage.user(text));
    });
    _textController.clear();
    _agentRespond(text);
    _scrollToBottom();
  }

  /// Slash-command dispatcher.  Returns `true` when the input was a
  /// recognised command and was fully handled here — in that case the
  /// caller MUST NOT forward the text to the LLM or the terminal.
  ///
  /// Currently supports:
  ///   /clear, /reset, /new   — wipe the chat (see `_clearChat`).
  ///   /help, /?              — show the command list (see `_showHelp`).
  ///
  /// Slash-commands are matched case-insensitively on the WHOLE trimmed
  /// input — `/clear`, `/CLEAR`, `/clear   ` all match, but
  /// `/clear something` does NOT (we treat that as a real prompt the
  /// user typed, in case they're talking ABOUT the command).
  bool _handleSlashCommand(String text) {
    final cmd = text.toLowerCase();
    switch (cmd) {
      case '/clear':
      case '/reset':
      case '/new':
        _clearChat();
        return true;
      case '/help':
      case '/?':
        _showHelp();
        return true;
      default:
        return false;
    }
  }

  /// Wipe the current mode's transcript, conversation history, and
  /// loop status.  Cancels any in-flight agent stream so cleared state
  /// stays cleared instead of being clobbered by late stream chunks.
  void _clearChat() {
    if (_agentBusy) _cancelAgent();
    setState(() {
      _messages.clear();
      _textController.clear();
      // Conversation history feeds the LLM context — wiping the visible
      // transcript without wiping this would leave the AI "remembering"
      // the previous task on the next prompt, which is surprising.
      _conversationHistory.clear();
      _agentLoopStatus = null;
      // No per-conversation skill bookkeeping to reset anymore — the
      // catalogue lives inside the system prompt (see
      // [LlmService._buildSkillsBlock]) so a wipe of conversation
      // history doesn't lose any skill visibility.
    });
  }

  /// Append a `/help` info banner to the visible chat WITHOUT pushing
  /// it into `_conversationHistory` — the LLM doesn't need to see help
  /// text in its context window.
  ///
  /// The body is markdown; it renders through `_buildMarkdown` so
  /// inline code and bold formatting work the same way as AI replies.
  ///
  /// IMPORTANT: when adding a new slash-command in `_handleSlashCommand`,
  /// add a row here too.  Two-place maintenance is unavoidable since
  /// the dispatcher needs lowercase exact-string keys while the help
  /// text needs human-readable descriptions — but they're both right
  /// here, side by side, so drift is easy to spot in code review.
  void _showHelp() {
    const helpText = '''
**Slash commands**

- `/clear`, `/reset`, `/new` — wipe the chat and the AI's memory of this conversation.
- `/help`, `/?` — show this list.

**Tips**

- Toggle **Auto-execute** to let the agent run commands automatically and iterate on the results.
- Type a real prompt to talk to the agent. Anything that doesn't start with a recognised `/command` is sent to the LLM as-is.
''';
    setState(() {
      _messages.add(_ChatMessage.notice(helpText));
      _textController.clear();
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    // Capture this before the next frame expands the transcript. Checking in
    // the post-frame callback would see the new max extent and mistake newly
    // appended content for a user scroll-away from the bottom.
    final shouldFollowLatest =
        !_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent -
                _scrollController.position.pixels <=
            24;
    if (!shouldFollowLatest) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `hasClients` alone is NOT sufficient — the controller can still
      // be alive on a disposed State (e.g. the user closed the panel
      // mid-stream).  Always re-check `mounted` first so we never call
      // animateTo on a disposed ScrollController.
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Resolve the panel's extent along its dock axis (height when docked
  /// bottom, width when docked right).  Clamps any persisted custom size
  /// to the current viewport so a window resized smaller can't leave the
  /// panel inflated past [_kPanelMaxFraction].
  double _panelExtent(BoxConstraints constraints) {
    final total = _position == AiPanelPosition.right
        ? constraints.maxWidth
        : constraints.maxHeight;
    final maxSide = (total * _kPanelMaxFraction).clamp(
      _kPanelMinExtent,
      double.infinity,
    );
    if (_customPanelSize != null) {
      return _customPanelSize!.clamp(_kPanelMinExtent, maxSide);
    }
    return (total * _kPanelDefaultFraction).clamp(_kPanelMinExtent, maxSide);
  }

  /// Flip dock side and clear the custom size so the new orientation
  /// starts at its default fraction (a width that fits the default % of
  /// the window often makes a poor height, and vice versa — picking a fresh
  /// default avoids the "thin slit" failure mode on rotation).
  void _togglePosition() {
    setState(() {
      _position = _position == AiPanelPosition.right
          ? AiPanelPosition.bottom
          : AiPanelPosition.right;
      _customPanelSize = null;
    });
    widget.onLayoutChanged?.call(_position, null);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return widget.child;

    // Paint a fill BEHIND the floating card so the 8 px margin strip
    // around the panel reads as the same surface as the card itself.
    //
    // We deliberately use `widget.terminalBackground` (= the active
    // terminal theme's chromeBackground — same colour the Scaffold,
    // tab bar, and TerminalView use) rather than `AppColors.popup`.
    // Why: `AppColors.popup` is derived from `chromeTabSelected`,
    // which lifts the base chromeBackground by ~16 % toward white —
    // a deliberate tint for menus and dialogs that need to "lift" off
    // the terminal.  For THIS panel we want the opposite: the strip,
    // the card, AND the surrounding chrome should all read as ONE
    // contiguous surface so the rounded card looks like a clip cut
    // out of a uniform bottom region, not a tinted overlay floating
    // on a slightly different bg.  The card still reads as a card
    // because PopupSurface still draws its 1 px border + depth shadow
    // — those carry the "floating" visual without a colour shift.
    //
    // Fallbacks (in order): terminalBackground → popup → frosted
    // default.  `terminalBackground` is null on tabs without a live
    // terminal (Settings, connecting, …), where popup is a fine
    // tinted default.
    final panelBg =
        widget.terminalBackground ??
        AppColors.maybeOf(context)?.popup ??
        FrostedGlassStyle.panelFillFrosted;

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelExtent = _panelExtent(constraints);
        final dockRight = _position == AiPanelPosition.right;

        // Padded card body.  The padding here IS the 8 px floating
        // margin around the rounded card — kept on the panel-card side
        // (not on the resize-handle side) so the handle sits flush
        // against the terminal pane and the user can grab the very
        // edge instead of hunting for the gap.
        final panelCard = Padding(
          padding: dockRight
              ? const EdgeInsets.fromLTRB(
                  0,
                  _kAiPanelMargin,
                  _kAiPanelMargin,
                  _kAiPanelMargin,
                )
              : const EdgeInsets.fromLTRB(
                  _kAiPanelMargin,
                  0,
                  _kAiPanelMargin,
                  _kAiPanelMargin,
                ),
          child: _AiPanelContent(
            busy: _agentBusy,
            autoExecute: _autoExecute,
            loopStatus: _agentLoopStatus,
            messages: _messages,
            textController: _textController,
            agentInputFocusNode: _agentInputFocusNode,
            scrollController: _scrollController,
            onSend: _send,
            onCancel: _cancelAgent,
            onAutoExecuteChanged: (v) => setState(() => _autoExecute = v),
            // Mirror `AgentConfig.markdownEnabled`'s true default so the
            // very first frame (before agentConfig has been wired in)
            // doesn't flash plain-text rendering and then "snap" to
            // markdown on the next rebuild.
            markdownEnabled: widget.agentConfig?.markdownEnabled ?? true,
            terminalBackground: widget.terminalBackground,
            terminalLineHeight: widget.terminalLineHeight,
            onWriteProposalDecision: _decideWriteProposal,
            onEditProposalDecision: _decideEditProposal,
            onDangerProposalDecision: _decideDangerProposal,
            onQuestionProposalDecision: _decideQuestionProposal,
            onQuestionProposalOther: _beginCustomQuestionAnswer,
            hasPendingQuestion: _pendingQuestionProposal != null,
            position: _position,
            onClear: _clearChat,
            onPositionToggle: _togglePosition,
          ),
        );

        // Resize handle lives on the edge that abuts the terminal pane.
        //   • bottom dock → top edge,  drag UP   ⇒ taller panel
        //   • right dock  → left edge, drag LEFT ⇒ wider  panel
        //
        // Dragging towards the terminal grows the panel, so we subtract
        // the delta (positive Y/X moves away from the terminal, which
        // should SHRINK the panel) — same convention SFTP uses.
        final handle = _AiResizeHandle(
          axis: dockRight ? Axis.horizontal : Axis.vertical,
          onDrag: (d) {
            setState(() {
              final total = dockRight
                  ? constraints.maxWidth
                  : constraints.maxHeight;
              final maxSide = total * _kPanelMaxFraction;
              final current = _customPanelSize ?? panelExtent;
              _customPanelSize = (current - d).clamp(_kPanelMinExtent, maxSide);
            });
            widget.onLayoutChanged?.call(_position, _customPanelSize);
          },
        );

        // Wrap the WHOLE panel area — handle + padded card — in a single
        // bg fill.  Without this, the 4 px transparent resize handle
        // would leak whatever sits behind it (Scaffold or the SFTP
        // floating overlay), showing up as a thin gap between the
        // terminal and the AI card.  Painting the same `panelBg` the
        // 8 px margin uses makes the handle area read as one contiguous
        // chrome strip with the rest of the card surround.
        final panelArea = ColoredBox(
          color: panelBg,
          child: dockRight
              ? Row(
                  children: [
                    handle,
                    Expanded(child: panelCard),
                  ],
                )
              : Column(
                  children: [
                    handle,
                    Expanded(child: panelCard),
                  ],
                ),
        );

        if (dockRight) {
          return Row(
            children: [
              Expanded(child: _buildTerminalBody()),
              SizedBox(width: panelExtent, child: panelArea),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: _buildTerminalBody()),
            SizedBox(height: panelExtent, child: panelArea),
          ],
        );
      },
    );
  }

  /// Returns the host-provided terminal unchanged. Agent commands run in a
  /// separate background process or SSH channel and never write to its PTY.
  Widget _buildTerminalBody() => widget.child;
}

// ── Logging helpers ─────────────────────────────────────────────────────────
//
// Single-line, structured `[agent] <event> key=val …` records.  Optimised
// for `flutter run` output where multi-line dumps wrapped onto subsequent
// lines and broke greppability — every meaningful event now fits on one
// line and follows the same shape so users can `grep '\[agent\] iter=2'`
// or `awk` over the stream.

/// Emit one structured `[agent] …` line.
void _logAgent(String event) {
  stdout.writeln('[agent] $event');
}

/// Emit a `[agent] iter=N stop reason=R` record at loop termination.
/// Centralised so every break path uses the same vocabulary (`task_complete`,
/// `ask_user`, `no_commands`, `auto_execute_off`, `no_executor`,
/// `max_iterations`, `stream_error_or_cancelled`).
///
/// [turnId] is the optional per-user-message counter that prefixes every
/// in-turn log line (`t=N`).  We accept null so the centralised helper
/// stays usable from any future caller that isn't inside the agent
/// loop's own `_continueAgentLoopBody` scope.
void _logAgentStop(int iter, String reason, {int? turnId}) {
  final prefix = turnId == null ? '' : 't=$turnId ';
  _logAgent('${prefix}iter=$iter stop reason=$reason');
}

/// Emit one structured `[safety] …` line for dangerous-command events.
///
/// Kept separate from `_logAgent` so `[safety]` can be grepped on its
/// own — useful for post-mortems where the question is "did the agent
/// ever trip a safety rule?" without sifting through every iteration log.
void _logSafety(String event) {
  stdout.writeln('[safety] $event');
}

/// Quote and escape a string for safe inclusion in a single-line log
/// record.  Newlines become `\n`, tabs `\t`, and the result is truncated
/// at 120 chars with an ellipsis so a 64 KB blob doesn't blow up the
/// terminal scrollback.  Always returns a double-quoted token.
String _logQuote(String s) {
  const cap = 120;
  var v = s
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  if (v.length > cap) v = '${v.substring(0, cap)}…';
  return '"$v"';
}

/// 4 px wide / tall transparent grab strip the user drags to resize the
/// AI panel.  Twin of `_ResizeHandle` in `ssh_session_view.dart` — kept
/// local so the AI panel library doesn't reach into the SFTP layer for
/// a private widget.
class _AiResizeHandle extends StatelessWidget {
  const _AiResizeHandle({required this.axis, required this.onDrag});

  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: axis == Axis.horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) =>
            onDrag(axis == Axis.horizontal ? d.delta.dx : d.delta.dy),
        child: Container(
          width: axis == Axis.horizontal ? 4 : double.infinity,
          height: axis == Axis.vertical ? 4 : double.infinity,
          color: Colors.transparent,
        ),
      ),
    );
  }
}
