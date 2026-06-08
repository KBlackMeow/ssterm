import 'dart:convert';
import 'dart:io' show stdout;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gpt_markdown/gpt_markdown.dart';

import '../io/output_pipe.dart' show CommandResult;
import '../models/agent_config.dart';
import '../models/skill.dart';
import '../services/llm_service.dart';
import '../services/file_write_service.dart';
import '../services/skill_service.dart';
import '../services/web_search_service.dart';
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
part 'ai_assistant_panel_loop.dart';

const _kFgActive = Color(0xFFD4D4D4);
const _kFgInactive = Color(0xFF8E8E8E);
const _kAccent = Color(0xFF2472C8);
const _kPanelMinHeight = 120.0;
const _kPanelDefaultFraction = 0.35;
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
const _maxHistoryTurns = 10;
const _maxLoopIterations = 15;

/// Number of head messages kept across truncation — typically the user's
/// initial task + the agent's first response.  Pinning these prevents the
/// agent from "forgetting its goal" when long auto-execute chains push the
/// conversation past [_maxHistoryTurns].
const _kPinnedHeadMessages = 2;

/// Cap per-command output we feed back to the LLM.  Real-world commands like
/// `tail -n 1000 /var/log/...` blow the context window otherwise.  We keep
/// the head + tail and elide the middle so the model still sees both the
/// command's banner and its final lines (which usually carry the verdict).
const _kMaxFeedbackBytes = 8 * 1024;
const _kFeedbackHeadBytes = 4 * 1024;
const _kFeedbackTailBytes = 4 * 1024;

enum AiPanelMode { command, agent }

class AiAssistantOverlay extends StatefulWidget {
  const AiAssistantOverlay({
    super.key,
    required this.child,
    required this.visible,
    this.onInsert,
    this.onExecute,
    this.onExecuteAsync,
    this.agentConfig,
    this.onGetShellIntegrationActive,
    this.terminalBackground,
    this.terminalLineHeight,
    this.onTerminalLockChanged,
    this.fileSystemAdapter,
  });

  final Widget child;
  final bool visible;

  /// Paste text into the active terminal (fill, no execute).
  final ValueChanged<String>? onInsert;

  /// Send text directly to the active session for execution.
  final ValueChanged<String>? onExecute;

  /// Execute a command and return its captured stdout/stderr + exit code
  /// (for the auto-execute agent loop).  The host application captures via
  /// OSC 133 shell integration when available, falling back to an
  /// echo-sentinel poll for shells without hooks installed.
  final Future<CommandResult?> Function(String cmd, {bool Function()? isCancelled})? onExecuteAsync;

  /// Agent provider configuration.
  final AgentConfig? agentConfig;

  /// Returns whether the active pane has OSC 133 shell integration active.
  /// `true` → industry-standard capture path; `false` → echo-sentinel
  /// fallback; `null` → no terminal pane.  The agent panel surfaces this so
  /// users know which capture path the agent is using.
  final bool? Function()? onGetShellIntegrationActive;

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

  /// Fires when the agent enters or leaves auto-execute mode and the
  /// host should lock (or unlock) the terminal pane against user input.
  ///
  /// The host is responsible for wrapping JUST the terminal in an
  /// `AbsorbPointer` — wrapping the whole session view here would also
  /// swallow clicks for the SFTP floating overlay that sits on top of
  /// the terminal in `SshSessionView`'s `Stack`, breaking the SFTP
  /// upload/download/navigate buttons while the agent works (SFTP runs
  /// on its own SSH channel and is unrelated to the PTY stdin we're
  /// guarding).
  final ValueChanged<bool>? onTerminalLockChanged;

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

  @override
  State<AiAssistantOverlay> createState() => _AiAssistantOverlayState();
}

class _AiAssistantOverlayState extends State<AiAssistantOverlay> {
  AiPanelMode _mode = AiPanelMode.command;

  // Separate state per mode
  final _cmdController = TextEditingController();
  final _agentController = TextEditingController();
  final _scrollController = ScrollController();
  final _agentMessages = <_ChatMessage>[];
  final _cmdMessages = <_ChatMessage>[];
  var _agentBusy = false;
  var _autoExecute = false;
  String? _agentLoopStatus;
  void Function()? _cancelStream;
  int _generation = 0;

  // Conversation history for agent mode (preserved across messages).
  final _conversationHistory = <Map<String, String>>[];

  /// True while the agent is auto-executing commands — terminal input is
  /// blocked to prevent the user from interfering with the agent's work.
  ///
  /// MUST only be mutated through [_setTerminalLocked] so the host overlay
  /// (which actually applies the `AbsorbPointer` around just the terminal
  /// pane — see `onTerminalLockChanged`) stays in sync.  Assigning this
  /// field directly would leave the SFTP overlay incorrectly blocked or
  /// the terminal incorrectly unlocked.
  var _terminalLocked = false;

  /// Single mutation point for [_terminalLocked].  Updates the local
  /// flag (so `_unfocusTerminalIfLocked` keeps working) AND notifies the
  /// host via `widget.onTerminalLockChanged` so it can wrap the terminal
  /// pane in an `AbsorbPointer`.  Keeping the two in lockstep here is
  /// what makes the SFTP floating overlay stay interactive while the
  /// agent is auto-executing.
  void _setTerminalLocked(bool locked) {
    if (_terminalLocked == locked) return;
    _terminalLocked = locked;
    widget.onTerminalLockChanged?.call(locked);
  }

  TextEditingController get _textController =>
      _mode == AiPanelMode.command ? _cmdController : _agentController;

  List<_ChatMessage> get _messages =>
      _mode == AiPanelMode.command ? _cmdMessages : _agentMessages;

  @override
  void dispose() {
    _cancelStream?.call();
    _cmdController.dispose();
    _agentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _cancelAgent() {
    _generation++;
    _cancelStream?.call();
    _cancelStream = null;
    setState(() {
      _agentBusy = false;
      _agentLoopStatus = null;
    });
    _setTerminalLocked(false);
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // Intercept slash-commands BEFORE the LLM / shell receives anything.
    // Returning true means "fully handled — do not fall through to send".
    if (_handleSlashCommand(text)) return;

    if (_mode == AiPanelMode.command) {
      setState(() {
        _messages.add(_ChatMessage.user(text));
      });
      _textController.clear();
      widget.onExecute?.call(text);
      _scrollToBottom();
      return;
    }

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
      if (_mode == AiPanelMode.agent) {
        _conversationHistory.clear();
        _agentLoopStatus = null;
        // No per-conversation skill bookkeeping to reset anymore — the
        // catalogue lives inside the system prompt (see
        // [LlmService._buildSkillsBlock]) so a wipe of conversation
        // history doesn't lose any skill visibility.
      }
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
- Click **Exec** on any AI reply that contains a fenced bash block to run that command manually through the same OSC 133 capture pipeline.
- Type a real prompt to talk to the agent. Anything that doesn't start with a recognised `/command` is sent to the LLM as-is.
''';
    setState(() {
      _messages.add(_ChatMessage.notice(helpText));
      _textController.clear();
    });
    _scrollToBottom();
  }


  /// Unfocus the primary focused widget if the terminal is currently locked.
  /// Called when locking starts and also from build() as a safety net.
  void _unfocusTerminalIfLocked() {
    if (!_terminalLocked || !mounted) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.hasFocus) {
      focus.unfocus();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  double _panelHeight(BoxConstraints constraints) {
    return (constraints.maxHeight * _kPanelDefaultFraction)
        .clamp(_kPanelMinHeight, constraints.maxHeight * _kPanelMaxFraction);
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
    final panelBg = widget.terminalBackground ??
        AppColors.maybeOf(context)?.popup ??
        FrostedGlassStyle.panelFillFrosted;

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelHeight = _panelHeight(constraints);
        return Column(
          children: [
            Expanded(child: _buildTerminalBody()),
            Container(
              height: panelHeight,
              color: panelBg,
              child: Padding(
                // Same 8px margin SFTP uses (`_kSftpPanelMargin`) so the AI
                // panel reads as a floating, rounded card consistent with the
                // SFTP card next door instead of a flat, edge-to-edge strip.
                padding: const EdgeInsets.fromLTRB(
                  _kAiPanelMargin,
                  0,
                  _kAiPanelMargin,
                  _kAiPanelMargin,
                ),
                child: _AiPanelContent(
                  mode: _mode,
                  busy: _agentBusy,
                  autoExecute: _autoExecute,
                  loopStatus: _agentLoopStatus,
                  messages: _messages,
                  textController: _textController,
                  scrollController: _scrollController,
                  onSend: _send,
                  onCancel: _cancelAgent,
                  onAutoExecuteChanged: (v) => setState(() => _autoExecute = v),
                  onInsert: widget.onInsert,
                  onSendToTerminal: widget.onExecute,
                  onRunManualCommand: widget.onExecuteAsync != null
                      ? _runManualCommand
                      : null,
                  onModeChanged: (m) => setState(() => _mode = m),
                  shellIntegrationActive:
                      widget.onGetShellIntegrationActive?.call(),
                  markdownEnabled:
                      widget.agentConfig?.markdownEnabled ?? false,
                  terminalBackground: widget.terminalBackground,
                  terminalLineHeight: widget.terminalLineHeight,
                  onWriteProposalDecision: _decideWriteProposal,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Returns the host-provided child unchanged.  The actual
  /// pointer-blocking `AbsorbPointer` that protects the terminal pane
  /// while the agent auto-executes lives in the HOST (see
  /// `main_views.dart`), driven by `onTerminalLockChanged`.  Wrapping
  /// `widget.child` here would also swallow clicks for the SFTP floating
  /// overlay that `SshSessionView` Stacks on top of the terminal —
  /// breaking the SFTP upload/download/navigate buttons whenever the
  /// agent runs a command.  SFTP traffic flows on its own SSH channel
  /// and has nothing to do with the PTY stdin we're guarding, so it
  /// must stay interactive.
  ///
  /// Progress is already surfaced inside the agent panel
  /// (`_agentLoopStatus` row), so no terminal-side scrim is needed.
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
void _logAgentStop(int iter, String reason) {
  _logAgent('iter=$iter stop reason=$reason');
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
