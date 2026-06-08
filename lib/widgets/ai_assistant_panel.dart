import 'dart:io' show stdout;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gpt_markdown/gpt_markdown.dart';

import '../io/output_pipe.dart' show CommandResult;
import '../models/agent_config.dart';
import '../models/skill.dart';
import '../services/llm_service.dart';
import '../services/skill_service.dart';
import 'frosted_glass.dart';

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

  /// Ids of skills already announced to the LLM via a `<system-reminder>`
  /// catalogue message earlier in THIS conversation.  Wiped on `/clear`
  /// alongside the rest of the chat state.
  ///
  /// Modelled after Claude Code's `sentSkillNames` map (attachments.ts) —
  /// in long sessions re-injecting the same 600-token catalogue on every
  /// user turn is pure waste.  We only ever announce the DELTA.  The
  /// listing itself is a real user message in the transcript, so the
  /// model continues to "see" it via context replay; we just don't pay
  /// the cost a second time.
  final _announcedSkillIds = <String>{};

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

  // Max conversation turns / loop iterations before we summarise old ones.
  static const _maxHistoryTurns = 10;
  static const _maxLoopIterations = 15;

  // Number of head messages kept across truncation — typically the user's
  // initial task + the agent's first response.  Pinning these prevents the
  // agent from "forgetting its goal" when long auto-execute chains push the
  // conversation past [_maxHistoryTurns].
  static const _kPinnedHeadMessages = 2;

  // Cap per-command output we feed back to the LLM.  Real-world commands like
  // `tail -n 1000 /var/log/...` blow the context window otherwise.  We keep
  // the head + tail and elide the middle so the model still sees both the
  // command's banner and its final lines (which usually carry the verdict).
  static const _kMaxFeedbackBytes = 8 * 1024;
  static const _kFeedbackHeadBytes = 4 * 1024;
  static const _kFeedbackTailBytes = 4 * 1024;

  /// Builds the user-role message that conveys a command's outcome to the
  /// LLM.  Uses a stable, easy-to-parse format so future iterations of the
  /// agent loop can reason about success/failure.
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
        // Re-announce the full skill catalogue on the next user turn,
        // since /clear semantically starts a brand-new conversation
        // (the prior `<system-reminder>` listing is no longer in history).
        _announcedSkillIds.clear();
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

  /// Single AI call + stream into the given [aiMsg] placeholder.
  /// Returns the full text or null on failure.
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

  /// Entry point used when the user types into the agent input.
  /// Adds [userText] to the conversation history and drives the loop.
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

    // Delta-announce any skills that haven't been advertised to the
    // LLM yet in THIS conversation.  Most common path: first user turn —
    // `_announcedSkillIds` is empty, so the full catalogue is appended.
    // Subsequent turns: usually a no-op (asset skills are static), but
    // if the bundled-skill registry ever grows mid-session, newcomers
    // are announced as a delta.
    //
    // The reminder is PREPENDED to the user message text instead of
    // being added as its own history entry, because Anthropic's
    // /v1/messages endpoint enforces strict user/assistant alternation
    // and two consecutive 'user' rows fail validation.  Embedding the
    // `<system-reminder>` tag inline lets all three providers (OpenAI,
    // Anthropic, Gemini) see it as a single user turn.  The wrapper
    // tag itself is enough of a visual / semantic boundary for the
    // model to treat the reminder as out-of-band meta.
    var finalUserContent = userText;
    // Apply the per-session enabled-skill whitelist BEFORE deciding what
    // to announce.  A disabled skill must never appear in the listing —
    // otherwise the model would happily try to load it and we'd have to
    // refuse mid-loop, wasting a round-trip.
    final enabledFilter = config.enabledSkills;
    final enabledIds = SkillService.filterEnabled(enabledFilter)
        .map((s) => s.id)
        .toSet();
    final unannounced = enabledIds
        .where((id) => !_announcedSkillIds.contains(id))
        .toList(growable: false);
    if (unannounced.isNotEmpty) {
      final reminder =
          LlmService.buildSkillListingReminder(include: unannounced);
      if (reminder.isNotEmpty) {
        finalUserContent = '$reminder\n\n$userText';
        _announcedSkillIds.addAll(unannounced);
        _logAgent('skill_listing announced=${unannounced.length} '
            'total=${_announcedSkillIds.length}');
      }
    }

    // The agent loop relies entirely on OSC 133 shell-integration capture
    // (with an echo-sentinel fallback) to surface terminal state to the LLM —
    // we no longer prepend a raw terminal-buffer snapshot, which used to
    // duplicate the same data in two formats and bloat context.
    _conversationHistory.add({'role': 'user', 'content': finalUserContent});

    await _continueAgentLoop(gen, config);
  }

  /// Manual "Exec" button on an AI message card.  Routes through the same
  /// capture pipeline as the auto-execute loop so the agent always sees a
  /// consistent view of the world — there is exactly ONE execution path.
  ///
  /// Behaviour:
  ///   1. Cancel any in-flight agent run.
  ///   2. Lock the terminal — the user MUST NOT type while we inject bytes
  ///      into the same PTY/SSH stdin stream.  Without this lock, a stray
  ///      Enter or paste interleaves with our command and either creates a
  ///      spurious OSC 133 C/D pair (skewing capture) or pollutes the
  ///      command line readline is currently editing.
  ///   3. Execute [cmd] with OSC 133 capture (or echo fallback).
  ///   4. Push a system "command card" into the chat.
  ///   5. Append the structured feedback to history as a `user` message.
  ///   6. Continue the loop ONCE — let the LLM react to the new evidence.
  ///      If auto-execute is off, the loop will break after the first AI
  ///      response, which preserves the user's "approve each step" workflow.
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

  /// Marks the agent busy and optionally locks the terminal pane against
  /// user input.  Idempotent for the current generation.
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

  /// The actual agent loop, shared between fresh user turns and manual
  /// "Exec" follow-ups.  Assumes the conversation history is already in a
  /// state where the next message is the assistant's.
  ///
  /// Wrapped in try/finally so that ANY exception from the LLM stream,
  /// the command-execute callback (e.g. SSH socket EOF), or our own UI
  /// updates leaves the agent in a recoverable state — the alternative
  /// is a permanently-busy panel with a permanently-locked terminal.
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
      final markerLabel = taskComplete
          ? 'task_complete'
          : (askUser
              ? 'ask_user'
              : (useSkill != null ? 'use_skill:$useSkill' : 'none'));
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelHeight = _panelHeight(constraints);
        return Column(
          children: [
            Expanded(child: _buildTerminalBody()),
            SizedBox(
              height: panelHeight,
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

  @override
  Widget build(BuildContext context) {
    final popupColor =
        AppColors.maybeOf(context)?.popup ?? FrostedGlassStyle.panelFillFrosted;

    return PopupSurface(
      color: popupColor,
      // Match SFTP's rounded, frosted-glass card look — same radius constant
      // as `_SftpFloatingChrome` so both panels read as siblings.
      radius: FrostedGlassStyle.panelRadius,
      backdropBlur: 20,
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

// ── Mode switch ────────────────────────────────────────────────────────────

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.mode,
    required this.onChanged,
    this.shellIntegrationActive,
  });

  final AiPanelMode mode;
  final ValueChanged<AiPanelMode> onChanged;
  final bool? shellIntegrationActive;

  @override
  Widget build(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          _TabChip(
            label: 'Command',
            icon: Icons.terminal,
            selected: mode == AiPanelMode.command,
            onTap: () => onChanged(AiPanelMode.command),
          ),
          const SizedBox(width: 8),
          _TabChip(
            label: 'Agent',
            icon: Icons.auto_awesome,
            selected: mode == AiPanelMode.agent,
            onTap: () => onChanged(AiPanelMode.agent),
          ),
          const Spacer(),
          if (mode == AiPanelMode.agent && shellIntegrationActive != null) ...[
            _ShellIntegrationBadge(active: shellIntegrationActive!),
            const SizedBox(width: 8),
          ],
          Text(
            mode == AiPanelMode.command ? 'Type & execute' : 'Ask & insert',
            style: TextStyle(color: dim, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _ShellIntegrationBadge extends StatelessWidget {
  const _ShellIntegrationBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF2EE767) : const Color(0xFFFFB454);
    final tooltip = active
        ? 'OSC 133 shell integration is active — '
            'agent captures clean stdout + exit codes.'
        : 'Shell integration not detected — '
            'agent uses an echo-sentinel fallback. '
            'Reopen the tab after upgrading to enable OSC 133.';
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(
              active ? 'shell integration' : 'echo fallback',
              style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dim = AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? _kAccent.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? _kAccent : dim.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: selected ? _kAccent : dim),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: selected ? _kAccent : dim,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}

// ── Reasoning section (collapsible thinking block) ──────────────────────────

class _ReasoningSection extends StatefulWidget {
  final String reasoning;
  const _ReasoningSection({required this.reasoning});

  @override
  State<_ReasoningSection> createState() => _ReasoningSectionState();
}

class _ReasoningSectionState extends State<_ReasoningSection> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: dim.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.unfold_less : Icons.unfold_more,
                  size: 12,
                  color: dim,
                ),
                const SizedBox(width: 4),
                Text(
                  _expanded ? 'Hide reasoning' : 'Show reasoning',
                  style: TextStyle(color: dim, fontSize: 11, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: dim.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: dim.withValues(alpha: 0.15)),
            ),
            child: Text(
              widget.reasoning,
              style: TextStyle(
                color: dim,
                fontSize: 12,
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}

// ── Command result card (collapsible) ──────────────────────────────────────

/// Inline "command executed" card shown in the agent transcript whenever the
/// auto-execute loop runs a command.  Mirrors what the LLM saw via OSC 133
/// shell integration so the user can spot-check the agent's view of reality.
class _CommandResultCard extends StatefulWidget {
  const _CommandResultCard({
    required this.command,
    required this.output,
    required this.exitCode,
  });

  final String command;
  final String output;
  final int? exitCode;

  @override
  State<_CommandResultCard> createState() => _CommandResultCardState();
}

class _CommandResultCardState extends State<_CommandResultCard> {
  static const _kCollapsedLines = 8;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive).withValues(alpha: 0.6);
    final out = widget.output;
    final lines = out.isEmpty ? const <String>[] : out.split('\n');
    final overflow = !_expanded && lines.length > _kCollapsedLines;
    final visible = overflow ? lines.sublist(0, _kCollapsedLines).join('\n') : out;

    return Container(
      decoration: BoxDecoration(
        color: dim.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: dim.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: $ command  +  exit badge
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    '\$ ${widget.command}',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontFamily: 'JetBrainsMono',
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _ExitBadge(exitCode: widget.exitCode),
              ],
            ),
          ),
          if (out.isNotEmpty) ...[
            Container(
              height: 1,
              color: dim.withValues(alpha: 0.12),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    visible,
                    style: TextStyle(
                      color: dim,
                      fontSize: 11,
                      fontFamily: 'JetBrainsMono',
                      height: 1.35,
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
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExitBadge extends StatelessWidget {
  const _ExitBadge({required this.exitCode});

  final int? exitCode;

  @override
  Widget build(BuildContext context) {
    final ({Color bg, Color fg, String label}) style;
    if (exitCode == null) {
      style = (
        bg: const Color(0xFF8E8E8E).withValues(alpha: 0.2),
        fg: const Color(0xFF8E8E8E),
        label: 'exit ?',
      );
    } else if (exitCode == 0) {
      style = (
        bg: const Color(0xFF2E7D32).withValues(alpha: 0.18),
        fg: const Color(0xFF2EE767),
        label: 'exit 0',
      );
    } else {
      style = (
        bg: const Color(0xFFFF6E67).withValues(alpha: 0.18),
        fg: const Color(0xFFFF6E67),
        label: 'exit $exitCode',
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        style.label,
        style: TextStyle(
          color: style.fg,
          fontSize: 10,
          fontFamily: 'JetBrainsMono',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Chat message model ─────────────────────────────────────────────────────

class _ChatMessage {
  String text;
  String? reasoning;
  final bool isUser;
  final bool isSystem;

  /// `true` for client-generated info banners (e.g. `/help` output).
  /// Notices are rendered with a small info-icon card distinct from
  /// user / AI / command-result messages, and are NEVER added to
  /// `_conversationHistory` — the LLM should never see them.
  ///
  /// IMPORTANT: typed as `bool?` (nullable) on purpose.  Flutter's hot
  /// reload swaps class definitions WITHOUT re-running constructors on
  /// already-allocated instances — so any `_ChatMessage` that lived in
  /// `_agentMessages` BEFORE this field existed has no storage slot for
  /// it, and reading `isNotice` on those legacy objects would return
  /// `null` from Dart's synthesized getter.  With a non-nullable `bool`
  /// that produces "type 'Null' is not a subtype of type 'bool'" the
  /// next time the panel rebuilds.  Keeping it nullable + always
  /// comparing with `== true` makes the code resilient to that scenario
  /// (and to any future deserialization paths that omit the field).
  final bool? isNotice;

  List<String>? commands;
  final String? error;

  /// For system "command card" messages: the command that was executed.
  final String? commandRun;

  /// For system "command card" messages: the exit code, or null when shell
  /// integration was not available and the code couldn't be captured.
  final int? commandExitCode;

  _ChatMessage._({
    required this.text,
    this.reasoning,
    required this.isUser,
    this.isSystem = false,
    this.isNotice = false,
    this.commands,
    this.error,
    this.commandRun,
    this.commandExitCode,
  });

  factory _ChatMessage.user(String text) => _ChatMessage._(text: text, isUser: true);

  factory _ChatMessage.ai({required String text, String? reasoning, List<String>? commands, String? error}) =>
      _ChatMessage._(text: text, reasoning: reasoning, isUser: false, commands: commands, error: error);

  /// Inline "command card" inserted into the chat after the agent loop runs
  /// a command.  [text] is the captured output (already cleaned of ANSI by
  /// `_executeAndCapture`); [commandRun] is what was sent to the shell;
  /// [commandExitCode] is null when shell integration was unavailable.
  factory _ChatMessage.system({
    required String text,
    required String commandRun,
    int? commandExitCode,
  }) => _ChatMessage._(
    text: text,
    isUser: false,
    isSystem: true,
    commandRun: commandRun,
    commandExitCode: commandExitCode,
  );

  /// Client-side notice (slash-command output, status hints, etc.).
  /// [text] supports markdown — it's piped through `_buildMarkdown` for
  /// `**bold**` and ``inline code`` rendering.
  factory _ChatMessage.notice(String text) => _ChatMessage._(
    text: text,
    isUser: false,
    isNotice: true,
  );
}

/// Custom fenced-code-block renderer for AI replies.
///
/// Replaces `gpt_markdown.CodeField` for two concrete reasons (see the
/// `codeBuilder:` call site in `_buildMarkdown` for the full why):
///
///   • Trims trailing whitespace from the captured code body — without
///     this, `gpt_markdown` 1.1.7 leaves a `\n` from the closing-fence
///     match in the body string, which renders as a phantom blank line
///     at the bottom of every block.
///   • Uses tighter padding than `EdgeInsets.all(16)` so short commands
///     (typical agent output is single-line) don't look stranded.
///
/// Visually this widget owns:
///   - background    = caller-provided `background` (the terminal pane
///                     bg, threaded through from `TerminalSettings`)
///   - mono font     = JetBrainsMono 13px, height = caller's lineHeight
///   - header strip  = compact language tag + Copy button, only shown
///                     when there's a language label or we have content
///                     worth copying (≥1 non-empty line)
class _AiCodeBlock extends StatefulWidget {
  const _AiCodeBlock({
    required this.name,
    required this.code,
    required this.background,
    required this.foreground,
    required this.lineHeight,
  });

  final String name;
  final String code;
  final Color background;
  final Color foreground;
  final double lineHeight;

  @override
  State<_AiCodeBlock> createState() => _AiCodeBlockState();
}

class _AiCodeBlockState extends State<_AiCodeBlock> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    // Drop ALL trailing whitespace (newlines, spaces, tabs).  This is
    // the line that fixes the "every code block has a blank line at
    // the bottom" complaint — see `codeBuilder:` comment for root cause.
    final code = widget.code.replaceFirst(RegExp(r'\s+$'), '');

    final dim = widget.foreground.withValues(alpha: 0.5);
    final showHeader = widget.name.isNotEmpty || code.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: widget.background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
              child: Row(
                children: [
                  if (widget.name.isNotEmpty)
                    Text(
                      widget.name,
                      style: TextStyle(
                        color: dim,
                        fontSize: 11,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: code));
                      if (!mounted) return;
                      setState(() => _copied = true);
                      await Future.delayed(const Duration(seconds: 2));
                      if (!mounted) return;
                      setState(() => _copied = false);
                    },
                    icon: Icon(
                      _copied ? Icons.check : Icons.content_copy,
                      size: 12,
                      color: dim,
                    ),
                    label: Text(
                      _copied ? 'Copied' : 'Copy',
                      style: TextStyle(color: dim, fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 24),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(12, showHeader ? 0 : 8, 12, 8),
            child: SelectableText(
              code,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 13,
                color: widget.foreground,
                height: widget.lineHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
