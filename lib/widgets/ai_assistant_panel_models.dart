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

  List<String>? commands;
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
    this.writeProposal,
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

  /// "File write proposal" card.  Rendered as a distinct Apply/Reject
  /// card by `_buildAgentMessage`; the contained [_WriteProposal] holds
  /// the mutable state machine driving the card.
  factory _ChatMessage.writeProposal(_WriteProposal proposal) =>
      _ChatMessage._(
        text: '',
        isUser: false,
        writeProposal: proposal,
      );
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
