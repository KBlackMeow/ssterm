part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// Data models — chat messages, file-write proposals, lifecycle enums.
//
// Extracted from `ai_assistant_panel.dart` to keep that file under the
// project-wide 1000-line cap.  All types are library-private (prefixed
// `_`) so callers outside this library never reach for them directly —
// the only public surface is [AiAssistantOverlay] in the main file.
// ───────────────────────────────────────────────────────────────────────────

// ── File-write proposal outcome (agent loop disposition) ──────────────────

/// Disposition the agent loop should take after `_proposeFileWrite`
/// processes a `[WRITE_FILE_BEGIN]` marker.  See `_proposeFileWrite`
/// for full semantics — kept in its own enum so the `switch` in the
/// agent loop is exhaustive and adding a third disposition later (e.g.
/// "auto-apply because path is in trusted-dirs") is a single point of
/// extension.
enum _WriteProposalOutcome {
  /// A failure / disabled envelope is already in conversation history.
  /// Loop should keep iterating so the model can react.
  injectedAndContinue,

  /// Preview succeeded; a chat card is displayed; loop should pause
  /// (return from the body so the wrapper's finally clears
  /// `_agentBusy` and unlocks the terminal).  Resume happens on
  /// Apply / Reject via `_decideWriteProposal`.
  waitingForUser,
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

  final String? error;

  /// For system "command card" messages: the command that was executed.
  final String? commandRun;

  /// For system "command card" messages: the exit code, or null when shell
  /// integration was not available and the code couldn't be captured.
  final int? commandExitCode;

  /// For "file write proposal" messages: the pending write the user
  /// must Apply or Reject before the agent loop resumes.  Mutable so
  /// the card UI can re-render through state transitions
  /// (pending → applying → applied/rejected/failed) without rebuilding
  /// the whole message list.  Null for every other message kind.
  ///
  /// Nullable (vs default null in `_` ctor) for the same hot-reload
  /// reason as [isNotice]: keeps already-allocated legacy `_ChatMessage`
  /// objects safe across class shape changes.
  _WriteProposal? writeProposal;

  /// For "dangerous command proposal" messages: the pending agent-emitted
  /// command the user must Approve or Reject before `_executeAndCapture`
  /// is allowed to forward it to the shell.  Same nullable / hot-reload
  /// rationale as [writeProposal].  Null for every other message kind.
  _DangerProposal? dangerProposal;

  /// For "ask-user question" messages: the pending multiple-choice
  /// question the user must answer (by tapping an option or typing a
  /// custom reply) before the agent loop resumes.  Same nullable /
  /// hot-reload rationale as [writeProposal].  Null for every other
  /// message kind.
  _QuestionProposal? questionProposal;

  _ChatMessage._({
    required this.text,
    this.reasoning,
    required this.isUser,
    this.isSystem = false,
    this.isNotice = false,
    this.error,
    this.commandRun,
    this.commandExitCode,
    this.writeProposal,
    this.dangerProposal,
    this.questionProposal,
  });

  factory _ChatMessage.user(String text) =>
      _ChatMessage._(text: text, isUser: true);

  factory _ChatMessage.ai({
    required String text,
    String? reasoning,
    String? error,
  }) => _ChatMessage._(
    text: text,
    reasoning: reasoning,
    isUser: false,
    error: error,
  );

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
  factory _ChatMessage.notice(String text) =>
      _ChatMessage._(text: text, isUser: false, isNotice: true);

  /// "File write proposal" card.  Rendered as a distinct Apply/Reject
  /// card by `_buildAgentMessage`; the contained [_WriteProposal] holds
  /// the mutable state machine driving the card.
  factory _ChatMessage.writeProposal(_WriteProposal proposal) =>
      _ChatMessage._(text: '', isUser: false, writeProposal: proposal);

  /// "Dangerous command proposal" card.  Rendered by
  /// `_buildAgentMessage` as a distinct Approve/Reject card with the
  /// rule label + command snippet; the contained [_DangerProposal]
  /// holds the mutable state machine driving the buttons.
  factory _ChatMessage.dangerProposal(_DangerProposal proposal) =>
      _ChatMessage._(text: '', isUser: false, dangerProposal: proposal);

  /// "Ask-user question" card — the structured sibling of the bare
  /// `[ASK_USER]` marker.  Rendered by `_buildAgentMessage` as a
  /// tappable option list (see `_QuestionProposalCard`); the contained
  /// [_QuestionProposal] holds the mutable state machine + the
  /// `Completer` the agent loop awaits.
  factory _ChatMessage.questionProposal(_QuestionProposal proposal) =>
      _ChatMessage._(text: '', isUser: false, questionProposal: proposal);
}

// ── File-write proposal (Apply/Reject card state machine) ──────────────────

/// Lifecycle states for an [_WriteProposal].
enum _WriteProposalState {
  /// Waiting for the user to click Apply or Reject.
  pending,

  /// Apply was clicked; the adapter's `commit` is in flight.  Card
  /// shows a spinner; both buttons are disabled to prevent
  /// double-submission.
  applying,

  /// The write completed successfully; [_WriteProposal.result] holds
  /// the post-commit metadata (bytes, mtime).
  applied,

  /// The user clicked Reject; no bytes hit disk.
  rejected,

  /// The adapter raised an exception during commit; the proposal is
  /// terminal (no retry button — the model is expected to react to
  /// the `[File write failed]` envelope on its next turn).
  failed,
}

/// Per-proposal record threaded through the chat-card UI and the
/// resume-the-loop callbacks.  Mutable on purpose: the card listens
/// for state changes via plain `setState` calls from the panel.
class _WriteProposal {
  /// Path as emitted by the model — preserved verbatim so the chat
  /// card can show what the LLM actually said even when the adapter
  /// resolved it to a different canonical form.
  final String requestedPath;

  /// Adapter-resolved absolute path (`~` expanded, etc.).  This is
  /// what `commit` will write to.
  final String resolvedPath;

  /// File body the model proposed — written byte-for-byte on Apply.
  final String content;

  /// Preview captured at the time the proposal was shown.  Drives the
  /// diff badge ("Create" vs "Overwrite") AND supplies the mtime used
  /// as a concurrency token in the commit call.
  final FileWritePreview preview;

  /// Generation counter snapshot.  If the user fires off a new agent
  /// request before clicking Apply, `_AiAssistantOverlayState._generation`
  /// bumps and this proposal becomes stale — clicks are silently
  /// converted into [rejected] without invoking the adapter.
  final int agentGeneration;

  _WriteProposalState state = _WriteProposalState.pending;

  /// Free-form short message surfaced in the card after a terminal
  /// state (typically the exception message or the reject reason).
  String? outcomeMessage;

  /// Set on successful commit so the card can show byte count + new
  /// mtime alongside the "Applied" badge.
  FileWriteResult? result;

  _WriteProposal({
    required this.requestedPath,
    required this.resolvedPath,
    required this.content,
    required this.preview,
    required this.agentGeneration,
  });
}

// ── Command proposal (Approve/Reject card state machine) ───────────────────
//
// Despite the name, [_DangerProposal] now backs TWO kinds of cards:
//   • verdict != null — a command `CommandSafety.danger()` flagged; card
//     shows the matched rule and always pauses regardless of auto-execute.
//   • verdict == null — an ordinary command proposed while auto-execute
//     is OFF; card shows a neutral "run this command?" prompt.  This is
//     what replaced the old bare "Exec" button — every manual command
//     now pauses for an explicit Approve/Reject, same mechanism as
//     dangerous commands always used.
// Kept as one type (rather than a new sibling class) because the two
// only ever differ in verdict-presence and card color — a parallel
// class would just duplicate the whole state machine.

/// Lifecycle states for a [_DangerProposal].  Mirrors
/// [_WriteProposalState] one-for-one (the agent loop's pause/resume
/// machinery already knows how to wait on a `Completer<bool>` with
/// these state transitions, so we reuse the shape verbatim).
enum _DangerProposalState {
  /// Waiting for the user to Approve or Reject the dangerous command.
  pending,

  /// Approved; the agent loop is in the process of executing the
  /// command via `_executeAndCapture`.  Buttons disabled so a stray
  /// double-tap can't kick off a second run.
  running,

  /// Command ran (regardless of exit code).  Result is in the chat
  /// history as the next system "command card"; this proposal card
  /// just shows a small "Approved" badge.
  ran,

  /// User clicked Reject.  No command hits the shell.  The loop
  /// receives a synthetic `[Dangerous command rejected by user]`
  /// envelope so the LLM can decide what to do next (typically: pick
  /// a less destructive alternative).
  rejected,
}

/// Per-proposal record for a dangerous agent command awaiting user
/// confirmation.  Created in `_executeAndCapture` whenever
/// `CommandSafety.danger(...)` returns non-null AND the policy's
/// `agentConfirmEnabled` is true.  Mutable on purpose — the chat card
/// re-renders via plain `setState` as the state field flips.
class _DangerProposal {
  /// The full command line as emitted by the LLM.  Shown verbatim in
  /// the confirmation card so the user can audit it before clicking
  /// Approve; truncated to a single line for the card header (long
  /// scripts expand on tap).
  final String command;

  /// Verdict from `CommandSafety.danger(...)`, or `null` when this card
  /// is an ordinary (non-dangerous) manual-mode confirmation — see the
  /// section comment above [_DangerProposalState].  Carries the rule id
  /// (for logs) and the one-line human label (shown as the card's
  /// subtitle, e.g. "Recursive force-delete of / (root filesystem)").
  final DangerVerdict? verdict;

  /// Generation counter snapshot.  Same staleness check as
  /// [_WriteProposal.agentGeneration]: if the user starts a fresh
  /// agent turn before answering, the older proposal silently
  /// resolves as [rejected] without invoking the shell.
  final int agentGeneration;

  _DangerProposalState state = _DangerProposalState.pending;

  /// Completer the agent loop awaits while the card is on screen.
  /// We use a Completer (vs the file-write pattern of "tear down loop
  /// → re-enter on click") because the agent loop is mid-for-loop over
  /// multiple commands when this fires — pausing in place keeps the
  /// remaining commands queued without us having to capture and replay
  /// the iteration state.  Completes with `true` on Approve, `false`
  /// on Reject (or when staleness detection auto-rejects).
  final Completer<bool> decision = Completer<bool>();

  _DangerProposal({
    required this.command,
    required this.verdict,
    required this.agentGeneration,
  });
}

// ── Ask-user question proposal (multiple-choice card state machine) ───────

/// One candidate answer inside an [_QuestionProposal].  Plain data
/// holder — no behaviour, mirrors how [ToolCall.options] in
/// `llm_service.dart` returns an anonymous record instead of this type
/// (that library can't see this private class, so the mapping happens
/// where the proposal is constructed — see `ai_assistant_panel_loop.dart`).
class _QuestionOption {
  final String label;
  final String description;

  const _QuestionOption({required this.label, required this.description});
}

/// Lifecycle states for a [_QuestionProposal].
enum _QuestionProposalState {
  /// Waiting for the user to tap an option or tap "Other".
  pending,

  /// User tapped "Other" — card shows an "answering below" hint and
  /// the main chat input is focused.  Still waiting on [decision].
  awaitingCustom,

  /// A final answer was recorded (option tap OR custom text submit)
  /// and [decision] has completed with it.
  answered,

  /// A newer agent generation started before this proposal was
  /// answered — same "stale" semantics as `_DangerProposalState` /
  /// `_WriteProposalState`.  [decision] completed with `null`.
  stale,
}

/// Per-proposal record for a pending `ask_user_question` tool call,
/// threaded through the chat-card UI and the agent loop's await point.
/// Mutable on purpose — the card listens for state changes via plain
/// `setState` calls from the panel, exactly like [_WriteProposal] /
/// [_DangerProposal].
class _QuestionProposal {
  /// The question text, verbatim from the model's `question` argument.
  final String question;

  /// Short chip label shown at the top of the card, verbatim from the
  /// model's `header` argument.
  final String header;

  /// Candidate answers, verbatim from the model — does NOT include the
  /// "Other" choice, which the card UI appends itself.
  final List<_QuestionOption> options;

  /// Generation counter snapshot.  If the user fires off a new agent
  /// request (or cancels) before answering, `_generation` bumps and
  /// this proposal becomes stale — same staleness convention as
  /// [_WriteProposal.agentGeneration] / [_DangerProposal.agentGeneration].
  final int agentGeneration;

  _QuestionProposalState state = _QuestionProposalState.pending;

  /// Set once [state] reaches [_QuestionProposalState.answered] — the
  /// exact text that was fed back to the LLM (an option's `label`, or
  /// whatever free text the user typed for "Other").
  String? answerText;

  /// Completer the agent loop awaits in place (mirrors
  /// [_DangerProposal.decision]).  Completes with the answer text on a
  /// real answer, or `null` when the proposal goes stale (cancelled /
  /// superseded) before one arrives.
  final Completer<String?> decision = Completer<String?>();

  _QuestionProposal({
    required this.question,
    required this.header,
    required this.options,
    required this.agentGeneration,
  });
}
