import 'dart:async';
import 'dart:convert';
import 'dart:io' show stdout, HttpException, Platform, SocketException;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
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
import '../services/agent_execution_budget.dart';
import '../services/agent_decision_policy.dart';
import '../services/agent_deliberation.dart';
import '../services/agent_session_store.dart';
import '../services/agent_session_registry.dart';
import '../services/agent_output_store.dart';
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
    final sessionId = _sessionRegistry.newSessionId();
    _sessionStore = AgentSessionStore(sessionId: sessionId);
    _outputStore = AgentOutputStore(sessionId: _sessionStore.sessionId);
    _createInitialSession(sessionId);
  }

  final _agentController = TextEditingController();
  final _scrollController = ScrollController();
  var _followLatestTranscript = true;
  var _scrollAnimationGeneration = 0;
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

  /// Pending write/edit proposals, kept so `_agentEngaged` can treat the
  /// "paused for Apply/Reject" state as still busy.  These two are NOT
  /// awaited in place (unlike danger/question proposals) — the loop returns
  /// `waitingForUser`, so `_agentBusy` drops to false while the card is up.
  _WriteProposal? _pendingWriteProposal;
  _EditProposal? _pendingEditProposal;

  /// User messages typed while the agent is engaged.  FIFO — each drains
  /// into its own agent turn once the current turn fully completes (see
  /// `_drainQueuedUserInput`), instead of interrupting the in-flight turn.
  final List<String> _pendingUserInput = [];

  /// Whether the agent is actively running OR paused on a user decision
  /// (write/edit proposal).  While true, new input is queued rather than
  /// interrupting the current turn.
  bool get _agentEngaged =>
      _agentBusy ||
      _pendingWriteProposal != null ||
      _pendingEditProposal != null;

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
  int? _lastAgentPromptTokenCount;
  AgentDecisionRun? _activeDecisionRun;
  AgentDecisionPlan? _activeDecisionPlan;
  final _sessionRegistry = AgentSessionRegistry();
  AgentSessionLease? _sessionLease;
  var _sessionNeedsTitle = true;
  late AgentSessionStore _sessionStore;
  late AgentOutputStore _outputStore;
  Future<void> _pendingSessionWrite = Future.value();

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
    _sessionLease?.release();
    super.dispose();
  }

  Future<void> _createInitialSession(String sessionId) async {
    final lease = await _sessionRegistry.createAndAcquire(sessionId: sessionId);
    if (!mounted || _sessionStore.sessionId != sessionId) {
      await lease.release();
      return;
    }
    _sessionLease = lease;
    for (final message in _messages) {
      if (message.isUser) {
        _nameSessionFrom(message.text);
        break;
      }
    }
  }

  Future<void> _createNewSession() async {
    final lease = await _sessionRegistry.createAndAcquire();
    if (!mounted) {
      await lease.release();
      return;
    }
    await _activateSession(lease, restore: false);
  }

  Future<void> _continueSession() async {
    final available = await _sessionRegistry.listAvailable();
    if (!mounted) return;
    final selected = await showDialog<AgentSessionDescriptor>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: _SessionPicker(
          sessions: available,
          onDelete: _deleteAvailableSession,
        ),
      ),
    );
    if (selected == null || !mounted) return;
    try {
      final lease = await _sessionRegistry.acquire(selected.id);
      if (!mounted) {
        await lease.release();
        return;
      }
      await _activateSession(lease, restore: true);
    } on AgentSessionUnavailableException {
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage.notice('That session was opened in another Agent tab.'),
        );
      });
    }
  }

  Future<void> _deleteAvailableSession(AgentSessionDescriptor session) async {
    try {
      await _sessionRegistry.delete(session.id);
    } on AgentSessionUnavailableException {
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage.notice('That session was opened in another Agent tab.'),
        );
      });
      rethrow;
    }
  }

  Future<void> _activateSession(
    AgentSessionLease lease, {
    required bool restore,
  }) async {
    final previous = _sessionLease;
    _pendingUserInput.clear();
    _pendingWriteProposal = null;
    _pendingEditProposal = null;
    if (_agentBusy) _cancelAgent();
    _sessionLease = lease;
    _sessionStore = AgentSessionStore(sessionId: lease.session.id);
    _outputStore = AgentOutputStore(sessionId: lease.session.id);
    _sessionNeedsTitle = lease.session.title == 'New session';
    setState(() {
      _messages.clear();
      _textController.clear();
      _conversationHistory.clear();
      _lastAgentPromptTokenCount = null;
      _agentLoopStatus = null;
    });
    if (restore) await _restoreSession();
    await previous?.release();
  }

  void _cancelAgent() {
    _generation++;
    _cancelStream?.call();
    _cancelStream = null;
    _cancelPendingAgentDecisions();
    // If the turn was interrupted between the model emitting a native tool
    // call and the loop recording its result, the conversation history ends
    // on a dangling `assistantToolCalls` item.  Backfill a synthetic tool
    // result so the next provider request doesn't 400 on "tool_use requires
    // a tool_result" (Anthropic) / "assistant tool_calls requires a tool
    // message" (OpenAI).
    _completeInterruptedToolCalls();
    _streamSession?.close(force: true);
    _streamSession = null;
    _streamSessionGeneration = null;
    _streamSessionPausedGeneration = null;
    _pendingWriteProposal = null;
    _pendingEditProposal = null;
    setState(() {
      _agentBusy = false;
      _agentLoopStatus = null;
      // A pending ask_user_question card's `await` would otherwise
      // leak forever once the loop that owns it has been abandoned —
      // force it to its stale terminal state here, same idea as the
      // lazy staleness check `_decideQuestionProposal` runs when a
      // card IS clicked after the fact, just done eagerly on cancel.
      _pendingQuestionProposal = null;
      // Flip any still-running command card to a terminal "stopped" state.
      // The loop's post-execute `commandRunning = false` assignment is
      // skipped on the cancel path (gen != _generation returns before it),
      // which would otherwise leave the card frozen at "运行中" forever.
      for (final message in _messages) {
        if (message.isSystem && message.commandRunning == true) {
          message.commandRunning = false;
          message.commandExitCode = null;
        }
        // Same for an approved-but-still-executing danger card: its
        // "RUNNING…" badge would otherwise stick forever.
        final danger = message.dangerProposal;
        if (danger != null && danger.state == _DangerProposalState.running) {
          danger.state = _DangerProposalState.stopped;
        }
      }
    });
    _queueSessionSave();
    // The user may have queued input while the cancelled turn was running —
    // hand it back off now that the turn is fully torn down.
    _drainQueuedUserInput();
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

    // While the agent is engaged (streaming, executing a tool, or paused on a
    // write/edit proposal), queue the input for the next round instead of
    // interrupting the in-flight turn.  The queued text becomes a fresh turn
    // once the current turn fully completes — see `_drainQueuedUserInput`.
    if (_agentEngaged) {
      _pendingUserInput.add(text);
      _textController.clear();
      setState(() {
        _messages.add(_ChatMessage.user(text));
      });
      _scrollToBottom();
      return;
    }

    setState(() {
      _messages.add(_ChatMessage.user(text));
    });
    _textController.clear();
    _nameSessionFrom(text);
    _agentRespond(text);
    _scrollToBottom();
  }

  void _nameSessionFrom(String text) {
    final lease = _sessionLease;
    if (!_sessionNeedsTitle || lease == null) return;
    _sessionNeedsTitle = false;
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final title = normalized.length <= 56
        ? normalized
        : '${normalized.substring(0, 56)}…';
    unawaited(_sessionRegistry.touch(lease.session.id, title: title));
  }

  /// Slash-command dispatcher.  Returns `true` when the input was a
  /// recognised command and was fully handled here — in that case the
  /// caller MUST NOT forward the text to the LLM or the terminal.
  ///
  /// Currently supports:
  ///   /clear, /reset — wipe the current chat (see `_clearChat`).
  ///   /new           — create a new Agent session.
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
        _clearChat();
        return true;
      case '/new':
        _createNewSession();
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
    // Drop queued input and pending write/edit proposals BEFORE cancelling
    // the in-flight turn — otherwise `_cancelAgent`'s tail drain would
    // resurrect a queued message on the freshly cleared chat.
    _pendingUserInput.clear();
    _pendingWriteProposal = null;
    _pendingEditProposal = null;
    if (_agentBusy) _cancelAgent();
    setState(() {
      _messages.clear();
      _textController.clear();
      // Conversation history feeds the LLM context — wiping the visible
      // transcript without wiping this would leave the AI "remembering"
      // the previous task on the next prompt, which is surprising.
      _conversationHistory.clear();
      _lastAgentPromptTokenCount = null;
      _agentLoopStatus = null;
      // No per-conversation skill bookkeeping to reset anymore — the
      // catalogue lives inside the system prompt (see
      // [LlmService._buildSkillsBlock]) so a wipe of conversation
      // history doesn't lose any skill visibility.
    });
    final sessionStore = _sessionStore;
    final outputStore = _outputStore;
    _pendingSessionWrite = _pendingSessionWrite
        .then((_) async {
          await sessionStore.clear();
          await outputStore.clear();
        })
        .catchError((_) {});
  }

  Future<void> _restoreSession() async {
    final result = await _sessionStore.load();
    if (!mounted || _conversationHistory.isNotEmpty) return;
    final snapshot = result.snapshot;
    if (snapshot == null || snapshot.items.isEmpty) return;
    setState(() {
      _conversationHistory.addAll(
        snapshot.items.map((item) => item.toConversationItem()),
      );
      for (final item in snapshot.items) {
        _messages.add(
          item.role == 'user'
              ? _ChatMessage.user(item.content)
              : _ChatMessage.ai(text: item.content),
        );
      }
      _messages.add(
        _ChatMessage.notice(
          'Restored the previous idle Agent transcript. No command or approval was resumed.',
        ),
      );
    });
  }

  void _queueSessionSave() {
    final sessionStore = _sessionStore;
    final snapshot = AgentSessionSnapshot.fromHistory(
      sessionId: sessionStore.sessionId,
      history: _conversationHistory,
    );
    _pendingSessionWrite = _pendingSessionWrite
        .then((_) => sessionStore.save(snapshot))
        .catchError((_) {});
  }

  /// Backfill a synthetic `tool_result` for the conversation history's
  /// trailing `assistantToolCalls` item (if any), so an interrupted turn
  /// leaves the transcript valid for the next provider request.
  ///
  /// Called from `_cancelAgent` right before the in-flight stream/session is
  /// torn down.  When the interruption lands between "model emitted native
  /// tool calls" and "loop recorded their results", history ends on a
  /// dangling assistant-tool-calls item with no following tool result — which
  /// Anthropic rejects ("tool_use requires a tool_result") and OpenAI rejects
  /// ("assistant tool_calls must be followed by a tool message").  Injecting
  /// an `isError` result keeps the transcript alternating and each tool call
  /// answered.
  void _completeInterruptedToolCalls() {
    if (_conversationHistory.isEmpty) return;
    final last = _conversationHistory.last;
    if (last.toolCalls.isEmpty) return;
    _conversationHistory.add(
      AgentConversationItem.toolResults([
        for (final call in last.toolCalls)
          AgentToolResult(
            toolCallId: call.id,
            content: '[Tool interrupted by user]',
            isError: true,
          ),
      ]),
    );
  }

  /// Dequeue the next queued user message and start a fresh agent turn for
  /// it.  No-op while the agent is still engaged or nothing is queued.
  void _drainQueuedUserInput() {
    if (!mounted || _agentEngaged || _pendingUserInput.isEmpty) return;
    _agentRespond(_pendingUserInput.removeAt(0));
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
    final isAtBottom =
        !_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent -
                _scrollController.position.pixels <=
            24;
    // Scrolling back down to the bottom resumes following.  We deliberately
    // do NOT pause following here when the view is away from the bottom:
    // programmatic growth (an empty assistant card, a status line) creates
    // transient gaps that would otherwise be misread as a user scroll-away
    // and permanently disable following.  Only genuine user scrolls (the
    // UserScrollNotification → _pauseFollowingLatestTranscript path) pause it.
    if (isAtBottom) _followLatestTranscript = true;
    if (!_followLatestTranscript) return;

    final animationGeneration = ++_scrollAnimationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `hasClients` alone is NOT sufficient — the controller can still
      // be alive on a disposed State (e.g. the user closed the panel
      // mid-stream).  Always re-check `mounted` first so we never call
      // animateTo on a disposed ScrollController.
      if (!mounted || animationGeneration != _scrollAnimationGeneration) {
        return;
      }
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _pauseFollowingLatestTranscript() {
    _followLatestTranscript = false;
    _scrollAnimationGeneration++;
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
            onTranscriptUserScroll: _pauseFollowingLatestTranscript,
            onSend: _send,
            onStop: _cancelAgent,
            queuedCount: _pendingUserInput.length,
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
            onNewSession: () => _createNewSession(),
            onContinueSession: () => _continueSession(),
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

class _SessionPicker extends StatefulWidget {
  const _SessionPicker({required this.sessions, required this.onDelete});

  final List<AgentSessionDescriptor> sessions;
  final Future<void> Function(AgentSessionDescriptor session) onDelete;

  @override
  State<_SessionPicker> createState() => _SessionPickerState();
}

class _SessionPickerState extends State<_SessionPicker> {
  late List<AgentSessionDescriptor> _sessions;
  String? _deleteError;
  String? _deletingSessionId;

  @override
  void initState() {
    super.initState();
    _sessions = List.of(widget.sessions);
  }

  Future<void> _delete(AgentSessionDescriptor session) async {
    setState(() {
      _deletingSessionId = session.id;
      _deleteError = null;
    });
    try {
      await widget.onDelete(session);
      if (!mounted) return;
      setState(() => _sessions.remove(session));
    } on AgentSessionUnavailableException {
      if (!mounted) return;
      setState(() {
        _deleteError = 'That session was opened in another Agent tab.';
      });
    } finally {
      if (mounted) setState(() => _deletingSessionId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.maybeOf(context);
    final foreground = colors?.foreground ?? _kFgActive;
    final foregroundDim = colors?.foregroundDim ?? _kFgInactive;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
      child: PopupSurface(
        color: FrostedGlassStyle.menuFillSolid,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Continue session',
                      style: TextStyle(
                        color: foreground,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: Icon(Icons.close, color: foregroundDim, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              if (_deleteError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _deleteError!,
                  style: TextStyle(color: foregroundDim, fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              Flexible(
                child: _sessions.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'No available sessions.',
                          style: TextStyle(color: foregroundDim),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _sessions.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final session = _sessions[index];
                          final deleting = _deletingSessionId == session.id;
                          return _SessionPickerCard(
                            session: session,
                            deleting: deleting,
                            foreground: foreground,
                            foregroundDim: foregroundDim,
                            onSelect: () => Navigator.of(context).pop(session),
                            onDelete: () => _delete(session),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionPickerCard extends StatefulWidget {
  const _SessionPickerCard({
    required this.session,
    required this.deleting,
    required this.foreground,
    required this.foregroundDim,
    required this.onSelect,
    required this.onDelete,
  });

  final AgentSessionDescriptor session;
  final bool deleting;
  final Color foreground;
  final Color foregroundDim;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  State<_SessionPickerCard> createState() => _SessionPickerCardState();
}

class _SessionPickerCardState extends State<_SessionPickerCard> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.deleting ? null : widget.onSelect,
        child: PopupSurface(
          color: _hovered
              ? const Color(0xFF303030)
              : FrostedGlassStyle.panelFillSolid,
          radius: 10,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                Icon(Icons.forum_outlined, size: 16, color: widget.foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: widget.foreground,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.session.updatedAt.toLocal().toString(),
                        style: TextStyle(
                          color: widget.foregroundDim,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Delete session',
                  onPressed: widget.deleting ? null : widget.onDelete,
                  icon: widget.deleting
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: widget.foregroundDim,
                          ),
                        )
                      : Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: widget.foregroundDim,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
