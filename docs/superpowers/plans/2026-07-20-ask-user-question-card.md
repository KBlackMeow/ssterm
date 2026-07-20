# AI Agent 问题选择框（ask_user_question 工具）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the ssterm AI agent ask the user a multiple-choice question (2–6 concrete options + an automatic "Other" free-text choice) via a tappable chat card, instead of forcing a free-text `[ASK_USER]` reply for every question.

**Architecture:** A new `ask_user_question` structured tool call (same JSON `tool_call` convention as `write_file`/`web_search`/`use_skill`) is parsed by `LlmService`, intercepted by the agent loop, and rendered as a `_QuestionProposalCard`. Unlike `write_file`/`web_search`, the interception does **not** end the turn — the loop `await`s a `Completer<String?>` in place (mirroring how `_DangerProposal.decision` is already awaited mid-loop), so the whole question/answer exchange stays inside one `turnId` with no `_agentBusy` flicker. The old free-text `[ASK_USER]` marker is untouched and stays available for open-ended questions.

**Tech Stack:** Flutter/Dart 3.11, `flutter_test`, existing `part`-file library structure under `lib/widgets/ai_assistant_panel*.dart` and `lib/services/llm_service*.dart`.

## Global Constraints

- Design doc of record: `docs/superpowers/specs/2026-07-20-ask-user-question-card-design.md` — every task below implements one section of it; do not diverge without re-checking that doc.
- One question per turn, options are single-select only (no `multiSelect`), 2–6 options, each option needs both a `label` and a `description`. No Settings toggle for this tool (always advertised).
- `_ChatMessage`, `_QuestionProposal`, `_QuestionProposalCard`, etc. are library-private (`_`-prefixed) classes living in `part of 'ai_assistant_panel.dart'` files — they are **not** importable from a separate test file (different library), so there is no automated test for them. Only the public `LlmService`/`ToolCall` layer (Tasks 1–2) gets automated tests, per the design doc's agreed test scope. Tasks 3–8 are verified with `flutter analyze` (must report "No issues found!") plus the manual QA checklist in Task 9.
- Every `part` file shares one library — cross-file references only need to compile by the end of the task that introduces them; each task below is ordered so the project compiles cleanly at the end of that task's steps.

---

### Task 1: `ask_user_question` tool-call parsing in `LlmService`

**Files:**
- Modify: `lib/services/llm_service.dart:38-93` (the `ToolCall` class), `lib/services/llm_service.dart:663-669` (`_isSupportedToolCall`)
- Test: `test/services/llm_service_test.dart` (inside the existing `group('LlmService.extractToolCalls', ...)` at line 188, after the `write_file` test at line 292)

**Interfaces:**
- Produces (used by Task 7 / `ai_assistant_panel_loop.dart`): `ToolCall.isAskUserQuestion` (`bool`), `ToolCall.question` (`String?`), `ToolCall.header` (`String?`), `ToolCall.options` (`List<({String label, String description})>`).

- [ ] **Step 1: Write the failing tests**

Open `test/services/llm_service_test.dart` and insert these tests immediately after the existing `test('extracts structured write_file calls', ...)` block (which ends at line 292, right before `test('extracts a tool_calls array with mixed supported tools', ...)`):

```dart
    test('extracts structured ask_user_question calls', () {
      const input = '''
```tool_call
{"id":"call_ask","name":"ask_user_question","arguments":{"question":"Which lockfile should I use?","header":"Lockfile","options":[{"label":"package-lock.json","description":"npm lockfile at repo root"},{"label":"pnpm-lock.yaml","description":"pnpm lockfile at repo root"}]}}
```
''';
      final calls = LlmService.extractToolCalls(input);
      expect(calls.single.isAskUserQuestion, isTrue);
      expect(calls.single.question, equals('Which lockfile should I use?'));
      expect(calls.single.header, equals('Lockfile'));
      expect(calls.single.options, hasLength(2));
      expect(calls.single.options.first.label, equals('package-lock.json'));
      expect(
        calls.single.options.first.description,
        equals('npm lockfile at repo root'),
      );
      expect(LlmService.extractCommands(input), isEmpty);
    });

    test('ask_user_question with only 1 option is rejected', () {
      const input = '''
```tool_call
{"id":"call_ask","name":"ask_user_question","arguments":{"question":"Proceed?","header":"Confirm","options":[{"label":"Yes","description":"Go ahead"}]}}
```
''';
      expect(LlmService.extractToolCalls(input), isEmpty);
    });

    test('ask_user_question with 7 options is rejected', () {
      final options = List.generate(
        7,
        (i) => '{"label":"opt$i","description":"desc$i"}',
      ).join(',');
      final input =
          '```tool_call\n'
          '{"id":"call_ask","name":"ask_user_question","arguments":{"question":"Pick one","header":"Pick","options":[$options]}}\n'
          '```\n';
      expect(LlmService.extractToolCalls(input), isEmpty);
    });

    test('ask_user_question with 6 options is accepted (upper bound)', () {
      final options = List.generate(
        6,
        (i) => '{"label":"opt$i","description":"desc$i"}',
      ).join(',');
      final input =
          '```tool_call\n'
          '{"id":"call_ask","name":"ask_user_question","arguments":{"question":"Pick one","header":"Pick","options":[$options]}}\n'
          '```\n';
      final calls = LlmService.extractToolCalls(input);
      expect(calls.single.options, hasLength(6));
    });

    test('ask_user_question missing header is rejected', () {
      const input = '''
```tool_call
{"id":"call_ask","name":"ask_user_question","arguments":{"question":"Proceed?","options":[{"label":"Yes","description":"Go ahead"},{"label":"No","description":"Stop"}]}}
```
''';
      expect(LlmService.extractToolCalls(input), isEmpty);
    });

    test('ask_user_question option missing description is dropped from the list', () {
      const input = '''
```tool_call
{"id":"call_ask","name":"ask_user_question","arguments":{"question":"Proceed?","header":"Confirm","options":[{"label":"Yes"},{"label":"No","description":"Stop"}]}}
```
''';
      // Only 1 of the 2 declared options survives parsing (missing
      // description) -> below the 2-option floor -> whole call rejected.
      expect(LlmService.extractToolCalls(input), isEmpty);
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/services/llm_service_test.dart --plain-name "ask_user_question"`
Expected: FAIL — `isAskUserQuestion`/`question`/`header`/`options` getters don't exist yet (compile error), or all six new tests fail once it compiles.

- [ ] **Step 3: Implement the getters and validation**

In `lib/services/llm_service.dart`, inside the `ToolCall` class, add after the existing `get content` getter (line 92, right before the class's closing `}` on line 93):

```dart
  bool get isAskUserQuestion =>
      name == 'ask_user_question' || name == 'ask_question';

  String? get question {
    final value = arguments['question'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  String? get header {
    final value = arguments['header'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  /// Candidate answers for [isAskUserQuestion] calls.  Returns a plain
  /// record (not a widget-layer type) because `ToolCall` lives in this
  /// library and must not depend on the private `_QuestionOption` class
  /// defined in `ai_assistant_panel_models.dart` — callers there map
  /// this into their own type.  Entries missing either `label` or
  /// `description` are silently dropped; [_isSupportedToolCall] then
  /// checks the post-filter count against the 2-6 bound.
  List<({String label, String description})> get options {
    final value = arguments['options'];
    if (value is! List) return const [];
    final out = <({String label, String description})>[];
    for (final item in value) {
      if (item is! Map) continue;
      final map = item.cast<String, Object?>();
      final label = map['label'];
      final description = map['description'];
      if (label is String &&
          label.trim().isNotEmpty &&
          description is String &&
          description.trim().isNotEmpty) {
        out.add((label: label.trim(), description: description.trim()));
      }
    }
    return out;
  }
```

Then update `_isSupportedToolCall` (line 663-669) from:

```dart
  static bool _isSupportedToolCall(ToolCall call) {
    if (call.isShell) return call.command != null;
    if (call.isUseSkill) return call.skillId != null;
    if (call.isWebSearch) return call.query != null;
    if (call.isWriteFile) return call.path != null && call.content != null;
    return false;
  }
```

to:

```dart
  static bool _isSupportedToolCall(ToolCall call) {
    if (call.isShell) return call.command != null;
    if (call.isUseSkill) return call.skillId != null;
    if (call.isWebSearch) return call.query != null;
    if (call.isWriteFile) return call.path != null && call.content != null;
    if (call.isAskUserQuestion) {
      return call.question != null &&
          call.header != null &&
          call.options.length >= 2 &&
          call.options.length <= 6;
    }
    return false;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/services/llm_service_test.dart`
Expected: PASS — all tests in the file, including the 6 new ones, green.

- [ ] **Step 5: Commit**

```bash
git add lib/services/llm_service.dart test/services/llm_service_test.dart
git commit -m "$(cat <<'EOF'
Parse ask_user_question structured tool calls in LlmService

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `<ask_user_question_tool>` system-prompt block

**Files:**
- Modify: `lib/services/llm_service_prompts.dart:13-25` (`_buildSystemPrompt`), `:40-82` (`_buildWebSearchBlock`, cross-reference line only), `:98-150` (`_buildFileWriteBlock`, cross-reference line only), `:186-215` (`_buildSkillsBlock`, cross-reference line only), `:343-419` (`<turn_protocol>` inside `_systemPromptBase`)
- Test: `test/services/llm_service_test.dart` (inside `group('LlmService.systemPromptFor', ...)` at line 792)

**Interfaces:**
- Consumes: nothing new from Task 1 (this is a pure string builder).
- Produces (used implicitly — this is prompt text the model reads, not a Dart API other tasks call): the `ask_user_question` tool description the model needs to actually emit the tool call Task 1 parses.

- [ ] **Step 1: Write the failing tests**

In `test/services/llm_service_test.dart`, inside `group('LlmService.systemPromptFor', ...)`, add after the last test in that group (`'all advertised tool_call examples are valid JSON'`, which ends at line 967, right before the group's closing `});`):

```dart
    test(
      'ask_user_question tool is always advertised regardless of feature flags',
      () {
        // Unlike web_search/write_file, this tool has no Settings gate —
        // it must appear even with every other optional feature off.
        final prompt = LlmService.systemPromptFor(
          enabledSkillIds: <String>{},
          webSearchEnabled: false,
          fileWriteEnabled: false,
        );
        expect(prompt.contains('<ask_user_question_tool>'), isTrue);
        expect(prompt.contains('"name":"ask_user_question"'), isTrue);
      },
    );

    test('turn_protocol documents ask_user_question as a 4th shape', () {
      final prompt = LlmService.systemPromptFor(enabledSkillIds: <String>{});
      expect(prompt.contains('ask_user_question'), isTrue);
      expect(prompt.contains('four shapes'), isTrue);
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/services/llm_service_test.dart --plain-name "ask_user_question tool is always advertised"`
Expected: FAIL — `<ask_user_question_tool>` not present in the prompt yet.

- [ ] **Step 3: Add the block and wire it in**

In `lib/services/llm_service_prompts.dart`, add this new top-level function right after `_buildSystemPrompt` (i.e. right before the `_buildWebSearchBlock` doc comment at line 27):

```dart
/// Returns the `<ask_user_question_tool>` block for the system prompt.
/// Always included — unlike `web_search`/`write_file`, asking a
/// question has no side effects and no Settings gate.
///
/// Structured sibling of the plain `[ASK_USER]` marker (still
/// documented in `<turn_protocol>`): this tool is for when the
/// candidate answers are enumerable (2-6 concrete options); `[ASK_USER]`
/// stays the fallback for genuinely open-ended questions.
String _buildAskUserQuestionBlock() {
  return '''
<ask_user_question_tool>
When you need the user to pick between a SMALL SET of concrete options (2-6), don't ask an open-ended question — emit one structured tool call and STOP:

```tool_call
{"id":"call_<short_unique_id>","name":"ask_user_question","arguments":{"question":"<one concrete question>","header":"<short label, max ~12 chars>","options":[{"label":"<short option title>","description":"<one-sentence explanation>"},{"label":"<short option title>","description":"<one-sentence explanation>"}]}}
```

Rules for `options`:
- Between 2 and 6 entries.
- Every entry needs BOTH a short `label` and a one-sentence `description` — never omit either.
- Do NOT add your own "other" / "something else" entry — ssterm's UI always appends one automatically for free-form answers.

The user is shown a card with your options as buttons; their answer arrives as an ordinary user-role message in your NEXT turn — no special envelope, just their chosen label (or whatever free text they typed if they picked "Other"). Treat it exactly like a normal reply and continue.

When to use it:
- The decision has a small number of concrete, nameable candidates (e.g. "which config file", "overwrite or rename", "which of these branches").
- You'd otherwise have written a question ending in "A, B, or C?" — that's the signal to use this tool instead of `[ASK_USER]`.

When NOT to use it (use the plain `[ASK_USER]` marker instead):
- The answer is genuinely open-ended (a name, a path, a secret, free-form instructions).
- There would be more than 6 options, or the options can't be boiled down to a short label + one sentence each.

Turn-shape rules:
- An `ask_user_question` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], [ASK_USER], `use_skill`, or `web_search` — the agent loop intercepts it BEFORE anything else, so combining silently drops later actions.
- The `question` field IS the question — don't also restate it as `[ASK_USER]` in the same turn.

Example INVESTIGATE-then-ASK turn:
  I found two lockfiles for this project.
  ```tool_call
  {"id":"call_pick_lockfile","name":"ask_user_question","arguments":{"question":"Which lockfile should I use for the install?","header":"Lockfile","options":[{"label":"package-lock.json","description":"npm's lockfile, present at the repo root"},{"label":"pnpm-lock.yaml","description":"pnpm's lockfile, also present at the repo root"}]}}
  ```
</ask_user_question_tool>''';
}
```

Then update `_buildSystemPrompt` (lines 13-25) from:

```dart
String _buildSystemPrompt({
  Set<String>? enabledSkillIds,
  bool webSearchEnabled = false,
  bool fileWriteEnabled = false,
}) {
  final parts = <String>[_systemPromptBase];
  final enabled = SkillService.filterEnabled(enabledSkillIds);
  if (enabled.isNotEmpty) parts.add(_buildSkillsBlock());
  if (webSearchEnabled) parts.add(_buildWebSearchBlock());
  if (fileWriteEnabled) parts.add(_buildFileWriteBlock());
  parts.add(_buildHostBlock());
  return parts.join('\n\n');
}
```

to:

```dart
String _buildSystemPrompt({
  Set<String>? enabledSkillIds,
  bool webSearchEnabled = false,
  bool fileWriteEnabled = false,
}) {
  final parts = <String>[_systemPromptBase, _buildAskUserQuestionBlock()];
  final enabled = SkillService.filterEnabled(enabledSkillIds);
  if (enabled.isNotEmpty) parts.add(_buildSkillsBlock());
  if (webSearchEnabled) parts.add(_buildWebSearchBlock());
  if (fileWriteEnabled) parts.add(_buildFileWriteBlock());
  parts.add(_buildHostBlock());
  return parts.join('\n\n');
}
```

Now update the three existing "MUST NOT combine" lines so they also name `ask_user_question`. In `_buildWebSearchBlock` (line 71), change:

```
- A `web_search` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], [ASK_USER], or `use_skill` — the agent loop intercepts the tool BEFORE executing anything, so combining silently drops later actions.
```

to:

```
- A `web_search` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], [ASK_USER], `ask_user_question`, or `use_skill` — the agent loop intercepts the tool BEFORE executing anything, so combining silently drops later actions.
```

In `_buildFileWriteBlock` (line 134), change:

```
- A `write_file` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], [ASK_USER], `use_skill`, or `web_search` — the agent loop intercepts the write BEFORE running anything, so combining silently drops later actions.
```

to:

```
- A `write_file` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], [ASK_USER], `ask_user_question`, `use_skill`, or `web_search` — the agent loop intercepts the write BEFORE running anything, so combining silently drops later actions.
```

In `_buildSkillsBlock` (line 207), change:

```
- A `use_skill` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], or [ASK_USER] — the agent loop intercepts the skill request BEFORE executing anything, so combining them silently drops later actions.
```

to:

```
- A `use_skill` tool call turn MUST NOT also contain a shell `tool_call`, [TASK_COMPLETE], [ASK_USER], or `ask_user_question` — the agent loop intercepts the skill request BEFORE executing anything, so combining them silently drops later actions.
```

Finally, update `<turn_protocol>` inside `_systemPromptBase`. Change:

```
<turn_protocol>
Every turn you write MUST be exactly ONE of these three shapes. NEVER combine.
```

to:

```
<turn_protocol>
Every turn you write MUST be exactly ONE of these four shapes. NEVER combine.
```

Then change:

```
  3. ASK — you need a decision, secret, or confirmation from the user before continuing.
     Format: One concrete question.
     End-of-turn marker: [ASK_USER] on its own line, last thing in the message.
     NO `tool_call` on this turn.

CRITICAL — DO NOT MIX SHAPES:
An INVESTIGATE turn (with a `tool_call`) MUST NOT also contain [TASK_COMPLETE] or [ASK_USER]. The agent loop checks the marker BEFORE executing your command — if both appear in the same turn, the marker wins, your command is silently dropped, and the round-trip is wasted. Always wait one full turn between issuing a command and declaring the task complete.
```

to:

```
  3. ASK — you need a decision, secret, or confirmation from the user before continuing.
     Format: One concrete question.
     End-of-turn marker: [ASK_USER] on its own line, last thing in the message.
     NO `tool_call` on this turn.

  4. ASK WITH OPTIONS — same as ASK, but the candidate answers are a SMALL SET of concrete, nameable options (2-6). Prefer this over shape 3 whenever you can enumerate the choices — see <ask_user_question_tool> for the full schema and a worked example.
     Format: One short sentence of intent, then one fenced `tool_call` JSON object naming `ask_user_question`.
     End-of-turn marker: NONE (the tool_call itself ends the turn).
     NO [ASK_USER] or any other marker on this turn.

CRITICAL — DO NOT MIX SHAPES:
An INVESTIGATE turn (with a `tool_call`) MUST NOT also contain [TASK_COMPLETE], [ASK_USER], or an `ask_user_question` tool_call. The agent loop checks the marker BEFORE executing your command — if both appear in the same turn, the marker wins, your command is silently dropped, and the round-trip is wasted. Always wait one full turn between issuing a command and declaring the task complete.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/services/llm_service_test.dart`
Expected: PASS — all tests, including the two new ones AND the pre-existing `'all advertised tool_call examples are valid JSON'` test (which now also validates the new block's example JSON automatically since it scans every ` ```tool_call ` fence in the prompt).

- [ ] **Step 5: Commit**

```bash
git add lib/services/llm_service_prompts.dart test/services/llm_service_test.dart
git commit -m "$(cat <<'EOF'
Advertise ask_user_question in the agent system prompt

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `_QuestionProposal` data model

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_models.dart` (append after `_DangerProposal`, ending at line 297; add fields/factory to `_ChatMessage`, lines 34-144)

**Interfaces:**
- Consumes: nothing (pure data classes).
- Produces (used by Tasks 4, 5, 6, 7, 8): `_QuestionOption({label, description})`, `_QuestionProposalState` enum (`pending`, `awaitingCustom`, `answered`, `stale`), `_QuestionProposal({question, header, options, agentGeneration})` with mutable `state`, `answerText`, and `decision` (`Completer<String?>`), and `_ChatMessage.questionProposal(proposal)` factory + `.questionProposal` field.

- [ ] **Step 1: Add the `_ChatMessage` field**

In `lib/widgets/ai_assistant_panel_models.dart`, find:

```dart
  _DangerProposal? dangerProposal;

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
  });
```

Replace with:

```dart
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
```

- [ ] **Step 2: Add the `_ChatMessage.questionProposal` factory**

In the same file, find:

```dart
  /// "Dangerous command proposal" card.  Rendered by
  /// `_buildAgentMessage` as a distinct Approve/Reject card with the
  /// rule label + command snippet; the contained [_DangerProposal]
  /// holds the mutable state machine driving the buttons.
  factory _ChatMessage.dangerProposal(_DangerProposal proposal) =>
      _ChatMessage._(text: '', isUser: false, dangerProposal: proposal);
}
```

Replace with:

```dart
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
```

- [ ] **Step 3: Append the new model classes**

At the end of the same file, find the final lines:

```dart
  _DangerProposal({
    required this.command,
    required this.verdict,
    required this.agentGeneration,
  });
}
```

Replace with (keeping that block and adding new classes after it):

```dart
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
```

- [ ] **Step 4: Verify the library still analyzes clean**

Run: `flutter analyze lib/widgets/ai_assistant_panel_models.dart`
Expected: `No issues found!`

(A transient `unused_element`-style hint for `_QuestionOption`/`_QuestionProposal`/`_ChatMessage.questionProposal` is possible until Task 6/7 start using them — if `flutter analyze` reports one, that's expected at this point in the plan, not a bug; it clears by the end of Task 7.)

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/ai_assistant_panel_models.dart
git commit -m "$(cat <<'EOF'
Add _QuestionProposal data model for the ask-user-question card

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `_QuestionProposalCard` widget

**Files:**
- Create: `lib/widgets/ai_assistant_panel_question_card.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart:28-34` (register the new `part`)

**Interfaces:**
- Consumes: `_QuestionProposal`, `_QuestionOption`, `_QuestionProposalState` (Task 3); top-level constants `_kFgActive`, `_kFgInactive`, `_kAccent` (`ai_assistant_panel.dart:36-38`); `AppColors.maybeOf(context)` (already used by `_DangerProposalCard`).
- Produces (used by Task 8): `_QuestionProposalCard({required proposal, required onOptionSelected, required onOther})` where `onOptionSelected` is `ValueChanged<String>` (called with the tapped option's `label`) and `onOther` is `VoidCallback`.

- [ ] **Step 1: Register the new part file**

In `lib/widgets/ai_assistant_panel.dart`, find:

```dart
part 'ai_assistant_panel_models.dart';
part 'ai_assistant_panel_widgets.dart';
part 'ai_assistant_panel_content.dart';
part 'ai_assistant_panel_write_card.dart';
part 'ai_assistant_panel_danger_card.dart';
part 'ai_assistant_panel_tooling.dart';
part 'ai_assistant_panel_loop.dart';
```

Replace with:

```dart
part 'ai_assistant_panel_models.dart';
part 'ai_assistant_panel_widgets.dart';
part 'ai_assistant_panel_content.dart';
part 'ai_assistant_panel_write_card.dart';
part 'ai_assistant_panel_danger_card.dart';
part 'ai_assistant_panel_question_card.dart';
part 'ai_assistant_panel_tooling.dart';
part 'ai_assistant_panel_loop.dart';
```

- [ ] **Step 2: Create the card widget**

Create `lib/widgets/ai_assistant_panel_question_card.dart`:

```dart
part of 'ai_assistant_panel.dart';

// ───────────────────────────────────────────────────────────────────────────
// _QuestionProposalCard — chat-card UI for a pending [_QuestionProposal].
//
// Structured sibling of the bare `[ASK_USER]` marker: the model supplied
// concrete candidate answers (`ask_user_question` tool call), so instead
// of a free-text prompt we render them as a tappable list, with an
// automatic "Other" row appended for anything not on the list. Visual
// sibling of [_DangerProposalCard] — same container / border / badge
// language — but the body is a vertical option list instead of a
// command line + Approve/Reject pair.
// ───────────────────────────────────────────────────────────────────────────

class _QuestionProposalCard extends StatelessWidget {
  const _QuestionProposalCard({
    required this.proposal,
    required this.onOptionSelected,
    required this.onOther,
  });

  final _QuestionProposal proposal;

  /// Called with the tapped option's `label` when the user picks a
  /// regular option row. Not called for "Other" — see [onOther].
  final ValueChanged<String> onOptionSelected;

  /// Called when the user taps the always-present "Other" row.
  final VoidCallback onOther;

  static const _kOtherLabel = 'Other';

  @override
  Widget build(BuildContext context) {
    final p = proposal;
    final fg = AppColors.maybeOf(context)?.foreground ?? _kFgActive;
    final dim = (AppColors.maybeOf(context)?.foregroundDim ?? _kFgInactive)
        .withValues(alpha: 0.7);
    final surface =
        AppColors.maybeOf(context)?.popup ?? const Color(0xAA1A1A1A);

    final accent = switch (p.state) {
      _QuestionProposalState.pending => _kAccent,
      _QuestionProposalState.awaitingCustom => _kAccent,
      _QuestionProposalState.answered => const Color(0xFF98C379), // green
      _QuestionProposalState.stale => dim,
    };
    final locked = p.state != _QuestionProposalState.pending;

    return Container(
      decoration: BoxDecoration(
        color: surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.6), width: 1.2),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildStateBadge(p.state, accent),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  p.header,
                  style: TextStyle(
                    color: accent,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            p.question,
            style: TextStyle(
              color: fg,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          for (final option in p.options)
            _buildOptionRow(
              label: option.label,
              description: option.description,
              selected: p.answerText == option.label,
              accent: accent,
              fg: fg,
              dim: dim,
              enabled: !locked,
              onTap: () => onOptionSelected(option.label),
            ),
          _buildOptionRow(
            label: _kOtherLabel,
            description: 'Type a custom answer',
            selected: p.state == _QuestionProposalState.awaitingCustom,
            accent: accent,
            fg: fg,
            dim: dim,
            enabled: !locked,
            onTap: onOther,
          ),
          if (p.state == _QuestionProposalState.awaitingCustom) ...[
            const SizedBox(height: 6),
            Text(
              'Type your answer in the box below and send it.',
              style: TextStyle(
                color: dim,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (p.state == _QuestionProposalState.stale) ...[
            const SizedBox(height: 6),
            Text(
              'Cancelled — newer conversation started before an answer was given.',
              style: TextStyle(color: dim, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionRow({
    required String label,
    required String description,
    required bool selected,
    required Color accent,
    required Color fg,
    required Color dim,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? accent.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: enabled ? onTap : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected
                    ? accent.withValues(alpha: 0.6)
                    : dim.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: enabled ? fg : dim,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(description, style: TextStyle(color: dim, fontSize: 11)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStateBadge(_QuestionProposalState state, Color accent) {
    final label = switch (state) {
      _QuestionProposalState.pending => 'QUESTION',
      _QuestionProposalState.awaitingCustom => 'ANSWERING…',
      _QuestionProposalState.answered => 'ANSWERED',
      _QuestionProposalState.stale => 'CANCELLED',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Verify the library still analyzes clean**

Run: `flutter analyze lib/widgets/`
Expected: `No issues found!` (the card class is still unused at this point — same expected transient hint as Task 3, if any).

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/ai_assistant_panel_question_card.dart lib/widgets/ai_assistant_panel.dart
git commit -m "$(cat <<'EOF'
Add _QuestionProposalCard widget for the ask-user-question UI

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Pending-question state field + focus node

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart:204-263` (state field declarations + `dispose()`)

**Interfaces:**
- Consumes: `_QuestionProposal` (Task 3).
- Produces (used by Tasks 6, 8): `_AiAssistantOverlayState._pendingQuestionProposal` (`_QuestionProposal?`), `_AiAssistantOverlayState._agentInputFocusNode` (`FocusNode`).

- [ ] **Step 1: Add the field declarations**

In `lib/widgets/ai_assistant_panel.dart`, find:

```dart
  var _agentBusy = false;
  var _autoExecute = false;
  String? _agentLoopStatus;
  void Function()? _cancelStream;
  int _generation = 0;
```

Replace with:

```dart
  var _agentBusy = false;
  var _autoExecute = false;
  String? _agentLoopStatus;
  void Function()? _cancelStream;
  int _generation = 0;

  /// The `_QuestionProposal` currently awaiting an answer (option tap OR
  /// custom "Other" text via the main chat input), or null when no
  /// `ask_user_question` card is pending.  Set when the card appears
  /// (see `ai_assistant_panel_loop.dart`'s `ask_user_question`
  /// interception) and cleared the moment it's answered or goes stale
  /// (see `_decideQuestionProposal` in `ai_assistant_panel_tooling.dart`).
  _QuestionProposal? _pendingQuestionProposal;

  /// Focus target for the agent-mode chat `TextField`, used ONLY to
  /// hand focus back to the input when the user taps "Other" on a
  /// pending question card — see `_beginCustomQuestionAnswer`.
  final _agentInputFocusNode = FocusNode();
```

- [ ] **Step 2: Dispose the new focus node**

In the same file, find:

```dart
  @override
  void dispose() {
    _cancelStream?.call();
    _cmdController.dispose();
    _agentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
```

Replace with:

```dart
  @override
  void dispose() {
    _cancelStream?.call();
    _cmdController.dispose();
    _agentController.dispose();
    _scrollController.dispose();
    _agentInputFocusNode.dispose();
    super.dispose();
  }
```

- [ ] **Step 3: Verify the library still analyzes clean**

Run: `flutter analyze lib/widgets/`
Expected: `No issues found!` (`_pendingQuestionProposal` unused-field hint, if any, is expected — cleared by Task 6).

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart
git commit -m "$(cat <<'EOF'
Add pending-question state field and focus node to the AI panel

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Decision helpers (`_decideQuestionProposal`, `_beginCustomQuestionAnswer`)

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart` (append two methods to `extension _AiAgentToolingExt on _AiAssistantOverlayState`)

**Interfaces:**
- Consumes: `_QuestionProposal`, `_QuestionProposalState` (Task 3); `_pendingQuestionProposal`, `_agentInputFocusNode` (Task 5); `_logAgent` (existing top-level helper in `ai_assistant_panel.dart`).
- Produces (used by Task 7 and Task 8): `_decideQuestionProposal(_QuestionProposal proposal, {required String answer})` — completes the proposal's `decision` and updates its visual state; `_beginCustomQuestionAnswer(_QuestionProposal proposal)` — flips the card to "awaiting custom" and focuses the chat input.

- [ ] **Step 1: Append the two methods**

In `lib/widgets/ai_assistant_panel_tooling.dart`, find the end of the file:

```dart
  String _formatCommandRejection(String cmd) {
    return '[Command rejected by user]\n'
        'Command: $cmd\n'
        'Do NOT retry this command verbatim. '
        'Either propose a different approach or ask the user to '
        'clarify what they actually want changed.';
  }
}
```

Replace with:

```dart
  String _formatCommandRejection(String cmd) {
    return '[Command rejected by user]\n'
        'Command: $cmd\n'
        'Do NOT retry this command verbatim. '
        'Either propose a different approach or ask the user to '
        'clarify what they actually want changed.';
  }

  /// Resolve a [_QuestionProposal] when the user taps an option button
  /// OR (for "Other") submits free text via the main chat input — see
  /// `_send()`'s pending-question short-circuit in
  /// `ai_assistant_panel.dart`.  Idempotent (a second call after the
  /// first is a no-op) and stale-conversation-safe: answering a
  /// proposal from an abandoned generation resolves it as [stale]
  /// without touching the new conversation's history — same shape as
  /// [_decideDangerProposal].
  void _decideQuestionProposal(
    _QuestionProposal proposal, {
    required String answer,
  }) {
    if (proposal.decision.isCompleted) return;

    if (proposal.agentGeneration != _generation) {
      setState(() => proposal.state = _QuestionProposalState.stale);
      _logAgent(
        'ask_user_question_stale header=${_logQuote(proposal.header)}',
      );
      proposal.decision.complete(null);
      return;
    }

    setState(() {
      proposal.state = _QuestionProposalState.answered;
      proposal.answerText = answer;
      if (identical(_pendingQuestionProposal, proposal)) {
        _pendingQuestionProposal = null;
      }
    });
    proposal.decision.complete(answer);
  }

  /// User tapped "Other" on a pending [_QuestionProposal].  Does NOT
  /// complete `proposal.decision` — just flips the card to its
  /// "answering below" hint state and hands focus to the main chat
  /// input.  The actual completion happens when `_send()` sees
  /// `_pendingQuestionProposal` still set and calls
  /// [_decideQuestionProposal] with whatever the user typed.
  void _beginCustomQuestionAnswer(_QuestionProposal proposal) {
    if (proposal.decision.isCompleted) return;
    setState(() => proposal.state = _QuestionProposalState.awaitingCustom);
    if (mounted) {
      FocusScope.of(context).requestFocus(_agentInputFocusNode);
    }
  }
}
```

- [ ] **Step 2: Verify the library still analyzes clean**

Run: `flutter analyze lib/widgets/`
Expected: `No issues found!` (these two methods are unused until Task 8 wires them into the UI callbacks — expected transient hint, if any).

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/ai_assistant_panel_tooling.dart
git commit -m "$(cat <<'EOF'
Add decision helpers for the ask-user-question card

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Agent-loop interception (pause in place, no `break`)

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart` (inside `_continueAgentLoopBody`: tool extraction around line 266-282, `markerLabel` around line 293-301, new interception block after the `writeFile` handling block ending around line 451)

**Interfaces:**
- Consumes: `ToolCall.isAskUserQuestion`/`.question`/`.header`/`.options` (Task 1); `_QuestionProposal`/`_QuestionOption` (Task 3); `_pendingQuestionProposal` (Task 5); `_ChatMessage.questionProposal`/`.user` (Task 3 / existing).
- Produces: nothing new for later tasks — this is the terminal integration point for the loop side. Task 8 covers the UI/click side.

- [ ] **Step 1: Extract the new tool call**

In `lib/widgets/ai_assistant_panel_loop.dart`, find:

```dart
      ToolCall? useSkillTool;
      ToolCall? webSearchTool;
      ToolCall? writeFileTool;
      for (final call in toolCalls) {
        if (useSkillTool == null && call.isUseSkill && call.skillId != null) {
          useSkillTool = call;
        }
        if (webSearchTool == null && call.isWebSearch && call.query != null) {
          webSearchTool = call;
        }
        if (writeFileTool == null &&
            call.isWriteFile &&
            call.path != null &&
            call.content != null) {
          writeFileTool = call;
        }
      }
```

Replace with:

```dart
      ToolCall? useSkillTool;
      ToolCall? webSearchTool;
      ToolCall? writeFileTool;
      ToolCall? askUserQuestionTool;
      for (final call in toolCalls) {
        if (useSkillTool == null && call.isUseSkill && call.skillId != null) {
          useSkillTool = call;
        }
        if (webSearchTool == null && call.isWebSearch && call.query != null) {
          webSearchTool = call;
        }
        if (writeFileTool == null &&
            call.isWriteFile &&
            call.path != null &&
            call.content != null) {
          writeFileTool = call;
        }
        if (askUserQuestionTool == null &&
            call.isAskUserQuestion &&
            call.question != null &&
            call.header != null &&
            call.options.length >= 2) {
          askUserQuestionTool = call;
        }
      }
```

- [ ] **Step 2: Add it to the `markerLabel` log line**

In the same file, find:

```dart
      final markerLabel = taskComplete
          ? 'task_complete'
          : (askUser
                ? 'ask_user'
                : (useSkill != null
                      ? 'use_skill:$useSkill'
                      : (webQuery != null
                            ? 'web_search'
                            : (writeFile != null ? 'write_file' : 'none'))));
```

Replace with:

```dart
      final markerLabel = taskComplete
          ? 'task_complete'
          : (askUser
                ? 'ask_user'
                : (askUserQuestionTool != null
                      ? 'ask_user_question'
                      : (useSkill != null
                            ? 'use_skill:$useSkill'
                            : (webQuery != null
                                  ? 'web_search'
                                  : (writeFile != null
                                        ? 'write_file'
                                        : 'none')))));
```

- [ ] **Step 3: Add the pause-in-place interception block**

In the same file, find the end of the file-write handling block, immediately followed by the terminus-handling comment:

```dart
          case _WriteProposalOutcome.waitingForUser:
            // Card is shown, loop is paused.  Return so the outer
            // `_continueAgentLoop`'s finally fires and unlocks the
            // terminal / clears _agentBusy; the Apply / Reject click
            // will call _continueAgentLoop again to resume.
            return;
        }
      }

      // Terminus handling.  Model-driven termini (`task_complete`,
```

Replace with:

```dart
          case _WriteProposalOutcome.waitingForUser:
            // Card is shown, loop is paused.  Return so the outer
            // `_continueAgentLoop`'s finally fires and unlocks the
            // terminal / clears _agentBusy; the Apply / Reject click
            // will call _continueAgentLoop again to resume.
            return;
        }
      }

      // ── Ask-user question (multiple-choice) ─────────────────────────
      // Structured sibling of the bare [ASK_USER] marker: the model
      // supplies concrete candidate answers, we show them as a card,
      // and — unlike write_file/web_search/use_skill — we do NOT end
      // the turn.  We await the user's answer in place (mirrors how
      // `_DangerProposal.decision` is awaited inside the command loop
      // below) so the whole exchange stays inside ONE `turnId`: no
      // `_agentBusy` flicker, no terminal unlock/relock, and the loop
      // calls the LLM again automatically the instant an answer lands.
      if (askUserQuestionTool != null) {
        final proposal = _QuestionProposal(
          question: askUserQuestionTool.question!,
          header: askUserQuestionTool.header!,
          options: askUserQuestionTool.options
              .map(
                (o) => _QuestionOption(
                  label: o.label,
                  description: o.description,
                ),
              )
              .toList(),
          agentGeneration: gen,
        );
        setState(() {
          _messages.add(_ChatMessage.questionProposal(proposal));
          _pendingQuestionProposal = proposal;
          _agentLoopStatus = 'Awaiting answer: ${proposal.header}';
        });
        _scrollToBottom();
        logIter(
          'iter=$loopIterations ask_user_question_shown '
          'header=${_logQuote(proposal.header)} '
          'options=${proposal.options.length}',
        );
        final answer = await proposal.decision.future;
        if (!mounted || gen != _generation) {
          logIter('iter=$loopIterations exit stale_generation');
          return;
        }
        if (answer == null) {
          // Cancelled while awaiting — bail without touching history,
          // mirrors the `webQuery` cancellation-during-fetch path above.
          return;
        }
        setState(() {
          _messages.add(_ChatMessage.user(answer));
          _agentLoopStatus = null;
        });
        _conversationHistory.add({'role': 'user', 'content': answer});
        logIter(
          'iter=$loopIterations ask_user_question_answered chars=${answer.length}',
        );
        _scrollToBottom();
        continue;
      }

      // Terminus handling.  Model-driven termini (`task_complete`,
```

- [ ] **Step 4: Verify the library still analyzes clean**

Run: `flutter analyze lib/widgets/`
Expected: `No issues found!` — this is the point where `_QuestionProposal`/`_QuestionOption`/`_ChatMessage.questionProposal` stop being "unused" (any transient hint from Tasks 3-6 should be gone now).

- [ ] **Step 5: Run the full test suite**

Run: `flutter test`
Expected: PASS — nothing in this task touches `LlmService`, so Task 1/2's tests (and everything else) should be unaffected.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/ai_assistant_panel_loop.dart
git commit -m "$(cat <<'EOF'
Intercept ask_user_question in the agent loop, pausing in place

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: UI wiring — Send hook, cancel sweep, card threading

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart:265-303` (`_cancelAgent`, `_send`), `:501-527` (the `_AiPanelContent(...)` call site in `build()`)
- Modify: `lib/widgets/ai_assistant_panel_content.dart:14-104` (`_AiPanelContent` fields/constructor), `:275-301` (agent-mode `TextField`), `:523-701` (`_buildAgentMessage`)

**Interfaces:**
- Consumes: `_decideQuestionProposal`, `_beginCustomQuestionAnswer` (Task 6); `_pendingQuestionProposal`, `_agentInputFocusNode` (Task 5); `_QuestionProposalCard` (Task 4).
- Produces: nothing further — this is the final integration point; Task 9 is verification only.

- [ ] **Step 1: Short-circuit `_send()` for a pending custom answer**

In `lib/widgets/ai_assistant_panel.dart`, find:

```dart
  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // Intercept slash-commands BEFORE the LLM / shell receives anything.
    // Returning true means "fully handled — do not fall through to send".
    if (_handleSlashCommand(text)) return;
```

Replace with:

```dart
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
```

- [ ] **Step 2: Sweep any pending question in `_cancelAgent()`**

In the same file, find:

```dart
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
```

Replace with:

```dart
  void _cancelAgent() {
    _generation++;
    _cancelStream?.call();
    _cancelStream = null;
    setState(() {
      _agentBusy = false;
      _agentLoopStatus = null;
      // A pending ask_user_question card's `await` would otherwise
      // leak forever once the loop that owns it has been abandoned —
      // force it to its stale terminal state here, same idea as the
      // lazy staleness check `_decideQuestionProposal` runs when a
      // card IS clicked after the fact, just done eagerly on cancel.
      final pendingQuestion = _pendingQuestionProposal;
      if (pendingQuestion != null && !pendingQuestion.decision.isCompleted) {
        pendingQuestion.state = _QuestionProposalState.stale;
        pendingQuestion.decision.complete(null);
      }
      _pendingQuestionProposal = null;
    });
    _setTerminalLocked(false);
  }
```

- [ ] **Step 3: Thread the focus node and new callbacks into `_AiPanelContent`**

In the same file, find the `_AiPanelContent(...)` construction inside `build()`:

```dart
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
            onModeChanged: (m) => setState(() => _mode = m),
            shellIntegrationActive: widget.onGetShellIntegrationActive?.call(),
            // Mirror `AgentConfig.markdownEnabled`'s true default so the
            // very first frame (before agentConfig has been wired in)
            // doesn't flash plain-text rendering and then "snap" to
            // markdown on the next rebuild.
            markdownEnabled: widget.agentConfig?.markdownEnabled ?? true,
            terminalBackground: widget.terminalBackground,
            terminalLineHeight: widget.terminalLineHeight,
            onWriteProposalDecision: _decideWriteProposal,
            onDangerProposalDecision: _decideDangerProposal,
            position: _position,
            onPositionToggle: _togglePosition,
          ),
```

Replace with:

```dart
          child: _AiPanelContent(
            mode: _mode,
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
            onInsert: widget.onInsert,
            onSendToTerminal: widget.onExecute,
            onModeChanged: (m) => setState(() => _mode = m),
            shellIntegrationActive: widget.onGetShellIntegrationActive?.call(),
            // Mirror `AgentConfig.markdownEnabled`'s true default so the
            // very first frame (before agentConfig has been wired in)
            // doesn't flash plain-text rendering and then "snap" to
            // markdown on the next rebuild.
            markdownEnabled: widget.agentConfig?.markdownEnabled ?? true,
            terminalBackground: widget.terminalBackground,
            terminalLineHeight: widget.terminalLineHeight,
            onWriteProposalDecision: _decideWriteProposal,
            onDangerProposalDecision: _decideDangerProposal,
            onQuestionProposalDecision: _decideQuestionProposal,
            onQuestionProposalOther: _beginCustomQuestionAnswer,
            position: _position,
            onPositionToggle: _togglePosition,
          ),
```

- [ ] **Step 4: Add the new constructor fields to `_AiPanelContent`**

In `lib/widgets/ai_assistant_panel_content.dart`, find:

```dart
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
    required this.onModeChanged,
    this.shellIntegrationActive,
    required this.markdownEnabled,
    this.terminalBackground,
    this.terminalLineHeight,
    this.onWriteProposalDecision,
    this.onDangerProposalDecision,
    required this.position,
    this.onPositionToggle,
  });
```

Replace with:

```dart
  const _AiPanelContent({
    required this.mode,
    required this.busy,
    required this.autoExecute,
    this.loopStatus,
    required this.messages,
    required this.textController,
    this.agentInputFocusNode,
    required this.scrollController,
    required this.onSend,
    required this.onCancel,
    this.onAutoExecuteChanged,
    required this.onInsert,
    required this.onSendToTerminal,
    required this.onModeChanged,
    this.shellIntegrationActive,
    required this.markdownEnabled,
    this.terminalBackground,
    this.terminalLineHeight,
    this.onWriteProposalDecision,
    this.onDangerProposalDecision,
    this.onQuestionProposalDecision,
    this.onQuestionProposalOther,
    required this.position,
    this.onPositionToggle,
  });
```

Then find:

```dart
  final List<_ChatMessage> messages;
  final TextEditingController textController;
  final ScrollController scrollController;
```

Replace with:

```dart
  final List<_ChatMessage> messages;
  final TextEditingController textController;

  /// Focus target for the agent-mode chat `TextField`.  Programmatically
  /// focused when the user taps "Other" on a pending question card —
  /// see `_AiAssistantOverlayState._beginCustomQuestionAnswer`.
  final FocusNode? agentInputFocusNode;
  final ScrollController scrollController;
```

Then find:

```dart
  /// Handler the [_DangerProposalCard] calls when the user clicks
  /// Approve or Reject.  Same pattern as [onWriteProposalDecision] —
  /// the panel stays a pure view, the state machine lives in
  /// [_AiAssistantOverlayState._decideDangerProposal].
  final void Function(_DangerProposal proposal, {required bool approve})?
  onDangerProposalDecision;
```

Replace with:

```dart
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
```

- [ ] **Step 5: Attach the focus node to the agent-mode `TextField`**

In the same file, find:

```dart
                          Expanded(
                            child: TextField(
                              controller: textController,
                              textInputAction: TextInputAction.send,
                              style: TextStyle(
                                color:
                                    AppColors.maybeOf(context)?.foreground ??
                                    _kFgActive,
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
                                contentPadding: EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  8,
                                  0,
                                ),
                                isDense: true,
                              ),
                              onSubmitted: (_) => onSend(),
                            ),
                          ),
```

Replace with:

```dart
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
                              ),
                              decoration: const InputDecoration(
                                hintText: 'Ask AI anything…',
                                hintStyle: TextStyle(
                                  color: Color(0xFF8E8E8E),
                                  fontSize: 13,
                                ),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  8,
                                  0,
                                ),
                                isDense: true,
                              ),
                              onSubmitted: (_) => onSend(),
                            ),
                          ),
```

- [ ] **Step 6: Render the card in `_buildAgentMessage`**

In the same file, find:

```dart
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
```

Replace with:

```dart
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
```

- [ ] **Step 7: Verify the library still analyzes clean**

Run: `flutter analyze lib/widgets/`
Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_content.dart
git commit -m "$(cat <<'EOF'
Wire the ask-user-question card into the chat UI and Send handler

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Full-suite verification + manual QA

**Files:** none (verification only).

**Interfaces:** none.

- [ ] **Step 1: Run the full analyzer**

Run: `flutter analyze`
Expected: `No issues found!` across the whole project.

- [ ] **Step 2: Run the full test suite**

Run: `flutter test`
Expected: All tests PASS, including every test added in Tasks 1-2 and every pre-existing test (nothing in this feature touches unrelated subsystems).

- [ ] **Step 3: Manual smoke test — launch the app**

Run: `flutter run -d macos` (or whichever desktop target the project normally targets)
Expected: App launches; open a terminal tab, open the AI assistant panel in Agent mode.

- [ ] **Step 4: Manual smoke test — trigger the card**

With a configured agent provider, send a prompt engineered to produce an enumerable choice, e.g.: `"I have two config files, config.dev.json and config.prod.json — ask me which one to use before doing anything else."`

Expected:
- A card appears showing the `header` chip, the question text, both options with label + description, and an "Other" row.
- Clicking a normal option: the card locks (highlighted row, "ANSWERED" badge), a new user-style chat bubble appears below it with that option's label, and the agent's next reply streams in automatically — **without** the send/stop button flipping to "stop" and back (confirming the loop stayed in place, matching the design's Section C intent).
- Clicking "Other" instead: the card shows the "ANSWERING…" badge + italic hint text, and the main chat input gains focus. Typing a custom answer and hitting Enter/Send: the card locks to "ANSWERED" with the custom text, a user bubble appears, and the loop continues the same way.

- [ ] **Step 5: Manual smoke test — cancel while a card is pending**

Trigger another question card, then click the Stop button (or send a completely unrelated new message) before answering.

Expected: the pending card flips to the "CANCELLED" badge with the "Cancelled — newer conversation started…" hint text; no crash, no stuck spinner; the new message/turn proceeds normally.

- [ ] **Step 6: Confirm the old free-text path still works**

Send a prompt likely to produce an open-ended question (e.g., `"Ask me for my name before continuing."`).

Expected: the AI's reply renders as a normal plain-text chat bubble ending in a question, with NO card — confirming `[ASK_USER]` is untouched and both mechanisms coexist per the design doc.

- [ ] **Step 7: Final commit (if any fixes were needed)**

If Steps 1-6 required any fixes, stage and commit them:

```bash
git add -A
git commit -m "$(cat <<'EOF'
Fix issues found during ask-user-question manual verification

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

If no fixes were needed, skip this step — Task 8's commit is the final one for this feature.
