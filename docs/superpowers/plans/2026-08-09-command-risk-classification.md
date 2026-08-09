# AI Command Risk Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let AI classify each shell command as normal, warning, or dangerous, merge that with a non-downgradable host fallback, enforce mode-specific confirmation, and show the final classification in feedback and result cards.

**Architecture:** Add a pure-Dart risk model/classifier beside `CommandSafety`, then thread one immutable assessment through tool parsing, the command loop, feedback formatting, chat messages, confirmation cards, and result cards. AI classification is primary, but the host computes a floor; missing/invalid AI values become warning, and the final level is the maximum of both inputs.

**Tech Stack:** Dart 3.11, Flutter, `flutter_test`, existing SSTerm agent tool and widget architecture. No new dependencies.

## Global Constraints

- Risk levels are exactly `normal`, `warning`, and `dangerous`.
- Final risk is `max(ai_level, host_level)`; host logic never lowers AI risk.
- Missing or invalid AI classification is treated as `warning`.
- Cautious mode confirms warning and dangerous commands; auto mode confirms dangerous commands only.
- Risk is based on command intent, not exit code.
- Confirmation is bound to the exact command and current Agent generation.
- Existing operational safety rejection remains independent and runs before execution.
- Feedback reasons must be single-line escaped host output; model text cannot forge headers.
- Existing persisted auto-execute configuration remains compatible.

---

## File Structure

- Create `lib/services/command_risk.dart`: risk enum, assessment, AI parsing, host fallback, level merge, and confirmation policy.
- Create `test/services/command_risk_test.dart`: focused pure-Dart tests for classification and confirmation.
- Modify `lib/services/agent_tool_contract.dart`: support enum values in generated JSON Schema.
- Modify `lib/services/agent_tool_registry.dart`: expose required `risk_level` and `risk_reason` bash arguments.
- Modify `lib/services/llm_service.dart`: expose parsed risk arguments on normalized `ToolCall`.
- Modify `lib/services/llm_service_prompts.dart`: document classification rules and feedback fields.
- Modify `lib/services/command_feedback_formatter.dart`: serialize the final risk assessment safely.
- Modify `lib/widgets/ai_assistant_panel_loop.dart`: classify, gate, log, execute, and propagate assessments.
- Modify `lib/widgets/ai_assistant_panel_models.dart`: carry assessments in proposals and system messages.
- Modify `lib/widgets/ai_assistant_panel_danger_card.dart`: render warning/danger confirmation semantics.
- Modify `lib/widgets/ai_assistant_panel_widgets.dart`: render result risk badge and reason.
- Modify `lib/widgets/ai_assistant_panel_content.dart`: pass risk assessment to the result card and label the non-auto state as cautious.
- Modify existing service/widget invariant tests where each boundary is exercised.

### Task 1: Pure command-risk model and host floor

**Files:**
- Create: `lib/services/command_risk.dart`
- Create: `test/services/command_risk_test.dart`
- Modify: `lib/services/command_safety.dart`

**Interfaces:**
- Produces: `enum CommandRiskLevel { normal, warning, dangerous }`
- Produces: `enum CommandRiskSource { ai, hostFallback, hostOverride, missingAiFallback }`
- Produces: `CommandRiskAssessment CommandRisk.assess({required String command, required String? aiLevel, required String? aiReason, required DangerousCommandsPolicy policy})`
- Produces: `bool CommandRisk.needsConfirmation(CommandRiskLevel level, {required bool autoExecute})`

- [ ] **Step 1: Write failing model and merge tests**

Test legal parsing, missing/invalid as warning, AI-dangerous preservation, host dangerous override for `git reset --hard`, host warning override for `rm -rf node_modules`, multiline maximum, and the two-mode confirmation matrix. Assert exact `level`, `source`, and non-empty reason.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `flutter test test/services/command_risk_test.dart`

Expected: FAIL because `package:ssterm/services/command_risk.dart` does not exist.

- [ ] **Step 3: Implement the minimal pure-Dart model**

Implement comparable enum levels, a const immutable assessment, strict string parsing, a high-confidence warning rule table, and:

```dart
static bool needsConfirmation(
  CommandRiskLevel level, {
  required bool autoExecute,
}) => level == CommandRiskLevel.dangerous ||
    (!autoExecute && level == CommandRiskLevel.warning);
```

Call the existing `CommandSafety.danger(command, policy)` for the dangerous host floor. Scan every non-empty line for warning rules and choose the maximum host level. Preserve the host verdict label when it overrides AI.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `flutter test test/services/command_risk_test.dart test/services/command_safety_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/command_risk.dart lib/services/command_safety.dart test/services/command_risk_test.dart
git commit -m "feat: classify agent command risk"
```

### Task 2: AI tool contract and prompt

**Files:**
- Modify: `lib/services/agent_tool_contract.dart`
- Modify: `lib/services/agent_tool_registry.dart`
- Modify: `lib/services/llm_service.dart`
- Modify: `lib/services/llm_service_prompts.dart`
- Modify: `test/services/agent_tool_contract_test.dart`
- Modify: `test/services/agent_tool_registry_test.dart`
- Modify: `test/services/llm_service_test.dart`

**Interfaces:**
- Consumes: `CommandRiskLevel` serialized with `.name`.
- Produces: `AgentToolParameter.stringEnum({required List<String> values, bool required, String? description})`.
- Produces: `ToolCall.riskLevel` and `ToolCall.riskReason` getters reading structured bash arguments.

- [ ] **Step 1: Write failing contract tests**

Assert that the bash schema requires `command`, `risk_level`, and `risk_reason`; that `risk_level` has JSON Schema enum values `['normal', 'warning', 'dangerous']`; and that a parsed native or legacy bash tool call exposes both risk arguments without affecting `command`.

- [ ] **Step 2: Run tests and verify RED**

Run: `flutter test test/services/agent_tool_contract_test.dart test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart`

Expected: FAIL because enum schema and risk getters are absent.

- [ ] **Step 3: Implement schema, parsing, and prompt guidance**

Extend `AgentToolParameter` with an optional enum list included in `toJsonSchema`. Add required risk fields to the registry bash definition. Add nullable getters that do no permissive coercion:

```dart
String? get riskLevel => arguments['risk_level'] is String
    ? arguments['risk_level'] as String
    : null;
String? get riskReason => arguments['risk_reason'] is String
    ? arguments['risk_reason'] as String
    : null;
```

Update both structured and legacy prompt examples to provide the fields. Define normal/warning/dangerous with examples and state that uncertainty must be warning. Update feedback examples with risk headers.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `flutter test test/services/agent_tool_contract_test.dart test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/agent_tool_contract.dart lib/services/agent_tool_registry.dart lib/services/llm_service.dart lib/services/llm_service_prompts.dart test/services/agent_tool_contract_test.dart test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart
git commit -m "feat: request AI command risk classifications"
```

### Task 3: Risk-aware feedback protocol

**Files:**
- Modify: `lib/services/command_feedback_formatter.dart`
- Modify: `test/services/command_feedback_formatter_test.dart`

**Interfaces:**
- Consumes: `CommandRiskAssessment` from Task 1.
- Produces: optional required-at-command-loop parameter `CommandRiskAssessment? risk` on `CommandFeedbackFormatter.format`.

- [ ] **Step 1: Write failing feedback tests**

Assert all final levels serialize as `[risk_level=<name>]`; `hostOverride` includes `[risk_ai_level=<original>]`; and a reason containing newline, `]`, or control characters remains a single bracketed metadata line and cannot inject `[output]`.

- [ ] **Step 2: Run test and verify RED**

Run: `flutter test test/services/command_feedback_formatter_test.dart`

Expected: FAIL because `format` does not accept an assessment or emit risk headers.

- [ ] **Step 3: Implement metadata serialization**

Insert risk headers immediately after `exit_code`. Add a private sanitizer that replaces CR/LF/control characters with spaces, escapes `]`, trims, and caps the reason at 240 characters. Keep the old optional call shape temporarily so unrelated callers compile; the command loop will always pass risk in Task 4.

- [ ] **Step 4: Run test and verify GREEN**

Run: `flutter test test/services/command_feedback_formatter_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/command_feedback_formatter.dart test/services/command_feedback_formatter_test.dart
git commit -m "feat: include command risk in tool feedback"
```

### Task 4: Mode-specific execution gate and exact-command binding

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel_danger_card.dart`
- Modify: `test/widgets/agent_panel_layout_invariants_test.dart`

**Interfaces:**
- Consumes: `CommandRisk.assess`, `CommandRisk.needsConfirmation`, and `ToolCall.riskLevel/riskReason`.
- Produces: `_DangerProposal.assessment` and `_ChatMessage.commandRisk`.

- [ ] **Step 1: Write failing source-level/widget invariant tests**

Assert the loop calls `CommandRisk.assess` with the exact trimmed command, uses `CommandRisk.needsConfirmation(... autoExecute: _autoExecute)`, passes the same assessment into the proposal, feedback formatter, and system message, and never uses `verdict != null || !_autoExecute`. Assert the proposal card branches warning to amber and dangerous to red.

- [ ] **Step 2: Run test and verify RED**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart`

Expected: FAIL because the command loop still confirms every non-auto command and carries only `DangerVerdict`.

- [ ] **Step 3: Implement assessment propagation and gate**

Import `command_risk.dart`. Compute exactly once before any confirmation:

```dart
final assessment = CommandRisk.assess(
  command: command,
  aiLevel: toolCall.riskLevel,
  aiReason: toolCall.riskReason,
  policy: config.dangerousPolicy,
);
final needsConfirm = CommandRisk.needsConfirmation(
  assessment.level,
  autoExecute: _autoExecute,
);
```

Replace proposal `verdict` with the immutable assessment, update log fields to level/source, and require `proposal.command == command` plus matching generation immediately before execution. Add `commandRisk` as a nullable hot-reload-safe field on system messages, but always provide it from this loop. Pass assessment to feedback formatting and result messages.

- [ ] **Step 4: Update confirmation-card semantics**

Render warning proposals with amber icon/border/copy and dangerous proposals with red. The card subtitle uses the normalized final reason; a `hostOverride` adds concise upgrade copy. Normal commands never create proposals in either mode.

- [ ] **Step 5: Run tests and verify GREEN**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart test/services/command_risk_test.dart`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_danger_card.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat: gate commands by final risk level"
```

### Task 5: Three-level result card and cautious-mode copy

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_widgets.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `test/widgets/agent_panel_layout_invariants_test.dart`

**Interfaces:**
- Consumes: `_ChatMessage.commandRisk` from Task 4.
- Produces: `_RiskBadge(assessment: CommandRiskAssessment?)` displayed next to `_ExitBadge`.

- [ ] **Step 1: Write failing card and copy invariants**

Assert `_CommandResultCard` requires the assessment, contains labels `普通`, `警告`, and `危险`, uses green/neutral, amber, and red branches, and preserves `_ExitBadge`. Assert the inactive toggle tooltip/help describes cautious behavior: ordinary commands run directly while warning and dangerous commands require confirmation.

- [ ] **Step 2: Run test and verify RED**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart`

Expected: FAIL because no result risk badge or cautious-mode explanation exists.

- [ ] **Step 3: Implement the result badge and reason display**

Pass `msg.commandRisk` into `_CommandResultCard`. Add a compact `_RiskBadge` beside `_ExitBadge`, map enum values exhaustively to Chinese labels and colors, and show `assessment.reason` in a tooltip. For a missing hot-reload field, display warning rather than silently showing normal.

- [ ] **Step 4: Update user-visible mode copy**

Keep the persisted boolean and compact `Auto` control. Update its tooltip/help text so inactive means cautious mode, not per-command manual approval. Do not rename persisted settings or introduce migration.

- [ ] **Step 5: Run tests and verify GREEN**

Run: `flutter test test/widgets/agent_panel_layout_invariants_test.dart`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/ai_assistant_panel_widgets.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel.dart test/widgets/agent_panel_layout_invariants_test.dart
git commit -m "feat: show command risk on result cards"
```

### Task 6: Full regression verification and documentation alignment

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-09-command-risk-classification-design.md` only if implementation exposes a necessary wording correction.

**Interfaces:**
- Consumes: completed end-to-end behavior from Tasks 1–5.
- Produces: verified feature and accurate user documentation.

- [ ] **Step 1: Update README behavior copy**

Document AI-primary/host-floor three-level classification, the cautious/auto confirmation matrix, and risk badges on results. Preserve the statement that dangerous operations always pause for approval.

- [ ] **Step 2: Format changed Dart files**

Run: `dart format lib/services/command_risk.dart lib/services/agent_tool_contract.dart lib/services/agent_tool_registry.dart lib/services/llm_service.dart lib/services/llm_service_prompts.dart lib/services/command_feedback_formatter.dart lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_danger_card.dart lib/widgets/ai_assistant_panel_widgets.dart lib/widgets/ai_assistant_panel_content.dart test/services/command_risk_test.dart test/services/agent_tool_contract_test.dart test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart test/services/command_feedback_formatter_test.dart test/widgets/agent_panel_layout_invariants_test.dart`

Expected: exits 0.

- [ ] **Step 3: Run focused feature tests**

Run: `flutter test test/services/command_risk_test.dart test/services/command_safety_test.dart test/services/agent_tool_contract_test.dart test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart test/services/command_feedback_formatter_test.dart test/widgets/agent_panel_layout_invariants_test.dart`

Expected: all tests PASS.

- [ ] **Step 4: Run the full test suite**

Run: `flutter test`

Expected: all tests PASS.

- [ ] **Step 5: Run static analysis**

Run: `flutter analyze`

Expected: no issues found.

- [ ] **Step 6: Review the final diff against the spec**

Run: `git diff --check && git status --short && git diff --stat HEAD~5`

Expected: no whitespace errors; only intended feature and documentation files are changed.

- [ ] **Step 7: Commit documentation**

```bash
git add README.md docs/superpowers/specs/2026-08-09-command-risk-classification-design.md
git commit -m "docs: explain command risk modes"
```
