# Agent Adaptive Decision Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an evidence-led deep decision path that improves a 27B model's verified recommendations without slowing simple SSTerm tasks.

**Architecture:** A pure policy layer routes a task before its first request and injects fixed user-side guidance. Tool-free planner, critic, and verifier calls create a structured decision record. The existing loop alone performs actions, then renders a concise decision report from real evidence.

**Tech Stack:** Flutter/Dart, `flutter_test`, `LlmService`, `AgentToolRegistry`, `AgentConversationHistory`.

## Global Constraints

- Preserve existing command-risk, approval, file-write, MCP, session, and compaction behavior.
- Retain a stable cached system prompt; route guidance is user-side content.
- Planning, critique, and verification calls expose no tools and cannot cause side effects.
- Deep runs allow five decision calls and at most two recovery calls with new evidence.
- Every setting defaults off per model until evaluation promotes it.
- Tool focus retains `bash` and `ask_user_question`, restores the complete catalogue after a durable tool result, and is not enabled for legacy Ollama in this scope.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/services/agent_decision_policy.dart` | Routing, decision JSON, budgets, and summary formatting. |
| `lib/services/agent_deliberation.dart` | Tool-free planner, critic, verifier calls. |
| `lib/services/llm_service.dart` | Request profiles and provider propagation. |
| `lib/services/agent_tool_registry.dart` | Native tool allowlisting. |
| `lib/models/agent_config.dart` | Per-model decision setting persistence. |
| `lib/views/settings/settings_sheet_agent.dart` | Selected-model settings controls. |
| `lib/widgets/ai_assistant_panel_loop.dart` | Routing, orchestration, recovery, summary lifecycle. |
| `lib/widgets/ai_assistant_panel_tooling.dart` | Profile-aware streaming and isolated deliberation sessions. |
| `test/services/agent_decision_policy_test.dart` | Policy, parser, accounting, summary tests. |
| `test/services/agent_deliberation_test.dart` | Tool-free request and fallback tests. |
| `test/models/agent_config_test.dart` | Persistence and migration tests. |
| `test/services/agent_tool_registry_test.dart` | Tool-focus tests. |
| `test/widgets/ai_assistant_panel_selection_test.dart` | Overlay ordering, safety, recovery, output invariants. |

### Task 1: Add pure route and decision types

**Files:**
- Create: `lib/services/agent_decision_policy.dart`
- Create: `test/services/agent_decision_policy_test.dart`

**Interfaces:**
- Produces `AgentDecisionRoute { fast, deep, uncertain }`, `AgentDecisionSettings`, `AgentDecisionPlan`, `AgentDecisionCritique`, `AgentVerificationVerdict`, `AgentDecisionRun`, and `AgentDecisionSummary`.
- Produces `AgentDecisionPolicy.classify(String task, AgentDecisionSettings settings)` and `guideFor(AgentDecisionRoute route)`.

- [ ] **Step 1: Write failing route and guidance tests**

```dart
test('uses fast route for a direct read', () {
  expect(AgentDecisionPolicy.classify('show current directory', enabled),
      AgentDecisionRoute.fast);
});
test('uses deep route for alternatives', () {
  expect(AgentDecisionPolicy.classify(
      'compare deployment plans and recommend the safest', enabled),
      AgentDecisionRoute.deep);
});
test('deep guide has completion anchors', () {
  final text = AgentDecisionPolicy.guideFor(AgentDecisionRoute.deep);
  expect(text, contains('architecture, constraints, edge cases'));
  expect(text, contains('decision or an information need'));
  expect(text, contains('unguided environment inspection'));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/agent_decision_policy_test.dart`

Expected: FAIL because the policy library does not exist.

- [ ] **Step 3: Implement the minimum route API**

```dart
enum AgentDecisionRoute { fast, deep, uncertain }
class AgentDecisionSettings {
  const AgentDecisionSettings({required this.enabled,
    required this.firstTurnToolFocus, this.maxDeepModelRequests = 5,
    this.maxRecoveryModelRequests = 2});
  final bool enabled, firstTurnToolFocus;
  final int maxDeepModelRequests, maxRecoveryModelRequests;
}
abstract final class AgentDecisionPolicy {
  static AgentDecisionRoute classify(String task, AgentDecisionSettings s) {
    if (!s.enabled || task.trim().isEmpty) return AgentDecisionRoute.fast;
    final text = task.toLowerCase();
    const deepWords = ['compare', 'recommend', 'alternative', 'migration',
      'deploy', 'risk', 'cost', 'failure', 'recovery', '比较', '推荐', '风险'];
    if (deepWords.any(text.contains)) return AgentDecisionRoute.deep;
    return task.trim().split(RegExp(r'\\s+')).length < 5
        ? AgentDecisionRoute.uncertain : AgentDecisionRoute.fast;
  }
  static String guideFor(AgentDecisionRoute route) => switch (route) {
    AgentDecisionRoute.fast => 'Use direct verifiable steps; finish when evidence is sufficient.',
    AgentDecisionRoute.deep => 'Consider architecture, constraints, edge cases, and integration points. End with a decision or an information need. Review completed work; do not perform unguided environment inspection.',
    AgentDecisionRoute.uncertain => 'Gather the minimum evidence needed to choose fast or deep work.',
  };
}
```

Classify explicit recommendation/comparison, alternatives, mutation, risk/cost, current information, and recovery tasks as deep; short ambiguous tasks as uncertain; disabled settings as fast. Guides are fixed, contain no host facts/secrets, and retain the three anchors: review completed work, finish with sufficient evidence, and avoid unguided exploration.

- [ ] **Step 4: Add failing JSON, accounting, and redaction tests**

```dart
test('rejects plans without two comparable candidates', () {
  expect(AgentDecisionPlan.tryParseJson('{"recommendedId":"a","candidates":[]}'), isNull);
});
test('recovery requires novel evidence', () {
  final run = AgentDecisionRun.deep(enabled);
  expect(run.requestRecovery(evidence: ''), isFalse);
  expect(run.requestRecovery(evidence: '[exit_code=1] compile failed'), isTrue);
});
test('summary omits private reasoning', () {
  expect(AgentDecisionSummary.format(fixture), isNot(contains('private_reasoning')));
});
```

- [ ] **Step 5: Implement strict structured records**

Parse via `dart:convert`. Require two or three uniquely identified candidates, each with fit, evidence, risk, cost, maintenance, and validation; recommendation names one candidate. `AgentDecisionRun` owns phase/recovery counts, evidence fingerprints, focus state, and fallback reason. Summary reads only structured recommendation/comparison/evidence/risk fields.

- [ ] **Step 6: Verify GREEN and commit**

Run: `flutter test test/services/agent_decision_policy_test.dart`

Expected: PASS.

Commit: `git add lib/services/agent_decision_policy.dart test/services/agent_decision_policy_test.dart && git commit -m "feat(agent): add adaptive decision policy"`

### Task 2: Persist selected-model settings

**Files:**
- Modify: `lib/models/agent_config.dart:646-930`
- Create: `test/models/agent_config_test.dart`
- Modify: `lib/views/settings/settings_sheet_agent.dart`

**Interfaces:**
- Produces `AgentConfig.decisionSettingsFor(String providerId, String model)` and `setDecisionSettings(String providerId, String model, AgentDecisionSettings)`.

- [ ] **Step 1: Write failing persistence tests**

```dart
test('missing settings defaults disabled', () {
  final c = AgentConfig.fromJson({'providers': const []});
  expect(c.decisionSettingsFor('ollama', 'qwen-27b').enabled, isFalse);
});
test('one model setting does not affect another', () {
  final c = AgentConfig();
  c.setDecisionSettings('ollama', 'qwen-27b', enabled);
  final restored = AgentConfig.fromJson(c.toJson());
  expect(restored.decisionSettingsFor('ollama', 'qwen-27b'), enabled);
  expect(restored.decisionSettingsFor('ollama', 'other-27b').enabled, isFalse);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/models/agent_config_test.dart`

Expected: FAIL because the per-model API is missing.

- [ ] **Step 3: Add migration-safe JSON and UI**

Store non-default entries only in `Map<String, AgentDecisionSettings> decisionSettingsByModel`, keyed by `'$providerId/$model'`; ignore malformed persisted values and clone the map in `copyWith`. Add an “Adaptive decision quality (experimental)” section in the current Agent settings sheet for the resolved model. It has enable and first-turn-tool-focus switches plus a fixed “5 decision + 2 recovery calls” label. It uses the sheet's existing save callback and never refreshes the system prompt.

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/models/agent_config_test.dart test/widgets/ai_assistant_panel_selection_test.dart`

Expected: PASS.

Commit: `git add lib/models/agent_config.dart lib/views/settings/settings_sheet_agent.dart test/models/agent_config_test.dart && git commit -m "feat(agent): add per-model decision settings"`

### Task 3: Add scoped model-request profiles and tool focus

**Files:**
- Modify: `lib/services/llm_service.dart:937-1027,1251-1355`
- Modify: `lib/services/agent_tool_registry.dart:41-130`
- Modify: `test/services/llm_service_test.dart`
- Modify: `test/services/agent_tool_registry_test.dart`

**Interfaces:**
- Produces `AgentRequestProfile({String? systemPromptOverride, Set<String>? allowedNativeToolNames})`.
- Adds optional `profile` to `LlmService.chat` and `chatStream`.
- Adds `AgentToolRegistry.limitedTo(Set<String>)`, which always retains `bash` and `ask_user_question` and preserves MCP normalization mapping.

- [ ] **Step 1: Write failing profile tests**

```dart
test('focused registry retains core tools only', () {
  final r = AgentToolRegistry.build(webSearchEnabled: true, fileWriteEnabled: true)
      .limitedTo({'bash'});
  expect(r.names, containsAll(['bash', 'ask_user_question']));
  expect(r.names, isNot(contains('web_search')));
});
test('tool-free profile does not invalidate default prompt cache', () {
  final p = LlmService.systemPromptFor(enabledSkillIds: const {});
  const profile = AgentRequestProfile(systemPromptOverride: 'JSON only',
      allowedNativeToolNames: {});
  expect(profile.allowsNativeTools, isFalse);
  expect(LlmService.systemPromptFor(enabledSkillIds: const {}), same(p));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart`

Expected: FAIL because profiles and filtering are absent.

- [ ] **Step 3: Implement profile propagation**

Default `profile == null` preserves today's prompt and full registry byte-for-byte. An override goes directly to provider adapters; a non-null allowlist filters native definitions. An empty set sends no native tools to OpenAI, Anthropic, and Gemini and uses a tool-free no-fenced-calls override for Ollama. Never include dynamic profile values in the default prompt cache key.

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart`

Expected: PASS, including existing provider serialization tests.

Commit: `git add lib/services/llm_service.dart lib/services/agent_tool_registry.dart test/services/llm_service_test.dart test/services/agent_tool_registry_test.dart && git commit -m "feat(agent): add scoped model request profiles"`

### Task 4: Implement tool-free planner, critic, and verifier

**Files:**
- Create: `lib/services/agent_deliberation.dart`
- Create: `test/services/agent_deliberation_test.dart`

**Interfaces:**
- `AgentDeliberation.plan`, `.critique`, and `.verify` each return nullable structured policy objects and invoke `LlmService.chat` with `allowedNativeToolNames: const {}`.

- [ ] **Step 1: Write failing deliberation tests**

```dart
test('planner uses strict JSON with no native tools', () {
  final r = AgentDeliberation.planRequest('compare deployment paths', enabled);
  expect(r.profile.allowedNativeToolNames, isEmpty);
  expect(r.profile.systemPromptOverride, contains('2 or 3 candidates'));
});
test('malformed planner response safely falls back', () {
  expect(AgentDeliberation.parsePlan('not json'), isNull);
});
test('verifier rejects unsupported completion', () {
  expect(AgentDeliberation.parseVerdict(
      '{"complete":false,"evidence":"test not run","recovery":"run test"}')!.complete,
      isFalse);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/agent_deliberation_test.dart`

Expected: FAIL because `AgentDeliberation` is absent.

- [ ] **Step 3: Implement fixed request builders**

Create fixed planning, critique, and verification system overrides. All explicitly prohibit tools and authorization, and request exactly one JSON object. Planner receives bounded task context; critic receives task plus plan and may only challenge assumptions/ranking; verifier receives plan, bounded real tool evidence, and final answer. Any network/parse/invalid-reference failure returns a typed failure with no same-phase retry, so the caller continues through the standard loop.

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/services/agent_deliberation_test.dart`

Expected: PASS.

Commit: `git add lib/services/agent_deliberation.dart test/services/agent_deliberation_test.dart && git commit -m "feat(agent): add tool-free decision deliberation"`

### Task 5: Route and critique before executable streaming

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart:57-340`
- Modify: `lib/widgets/ai_assistant_panel_tooling.dart:73-285`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- `_activeDecisionRun` is nullable per-overlay state.
- `_streamAiResponse(..., {AgentRequestProfile? profile})` forwards its profile to `LlmService.chatStream`.

- [ ] **Step 1: Write failing ordering and safety tests**

```dart
test('deep route plans and critiques before executable loop', () {
  final s = File('lib/widgets/ai_assistant_panel_loop.dart').readAsStringSync();
  expect(s.indexOf('AgentDecisionPolicy.classify'),
      lessThan(s.indexOf('_continueAgentLoop(gen, config)')));
  expect(s, contains('AgentDeliberation.plan'));
  expect(s, contains('AgentDeliberation.critique'));
});
test('deliberation profile exposes no native tools', () {
  final s = File('lib/widgets/ai_assistant_panel_tooling.dart').readAsStringSync();
  expect(s, contains('allowedNativeToolNames: const {}'));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: FAIL because routing orchestration is absent.

- [ ] **Step 3: Add first-turn orchestration**

In `_agentRespond`, reset run state, derive selected-model settings, classify before appending the first history item, and append the fixed route guide after session/environment context. For deep tasks, use fresh `AgentStreamClientSession`s to call planner then critic. If both parse, append host-authored `<decision_plan>` containing revised recommendation and validation criteria. If either fails, append an explicit fallback block and use current execution. Apply first-turn native focus only for the first executable request, retaining core tools plus tools the plan explicitly requires; clear it after an actual tool result. Do not focus legacy Ollama.

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: PASS; direct tasks do not call planner or critic.

Commit: `git add lib/widgets/ai_assistant_panel_loop.dart lib/widgets/ai_assistant_panel_tooling.dart test/widgets/ai_assistant_panel_selection_test.dart && git commit -m "feat(agent): route and critique complex tasks"`

### Task 6: Verify completion and bound recovery

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_loop.dart:680-965`
- Modify: `test/services/agent_decision_policy_test.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- `_verifyDeepOutcome(gen, config, run, finalAnswer, evidence) -> Future<AgentVerificationVerdict?>`.

- [ ] **Step 1: Write failing verifier tests**

```dart
test('deep completion verifies before taskComplete exits', () {
  final s = File('lib/widgets/ai_assistant_panel_loop.dart').readAsStringSync();
  expect(s.indexOf('_verifyDeepOutcome'), lessThan(s.indexOf('if (taskComplete)'));
});
test('repeated evidence cannot re-plan twice', () {
  final run = AgentDecisionRun.deep(enabled);
  expect(run.requestRecovery(evidence: 'compile error'), isTrue);
  expect(run.requestRecovery(evidence: 'compile error'), isFalse);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/agent_decision_policy_test.dart test/widgets/ai_assistant_panel_selection_test.dart`

Expected: FAIL because terminal verification is absent.

- [ ] **Step 3: Implement the verifier gate**

Before breaking on `[TASK_COMPLETE]` for an active deep run, collect bounded recent structured tool results and final displayed text, then invoke tool-free verification. A complete verdict records its evidence/risk and exits. An incomplete verdict may append host-authored `<verification_recovery>` and continue only when `requestRecovery` accepts new evidence within budget. Null, repeated, or exhausted verdict adds an explicit unverified-risk status and never repeats commands or claims success.

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/services/agent_decision_policy_test.dart test/widgets/ai_assistant_panel_selection_test.dart`

Expected: PASS.

Commit: `git add lib/widgets/ai_assistant_panel_loop.dart test/services/agent_decision_policy_test.dart test/widgets/ai_assistant_panel_selection_test.dart && git commit -m "feat(agent): verify deep decision outcomes"`

### Task 7: Render decision report and diagnostics

**Files:**
- Modify: `lib/widgets/ai_assistant_panel_models.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`

**Interfaces:**
- `_ChatMessage.decisionSummary(AgentDecisionSummary)` is display-only and has no model reasoning field.

- [ ] **Step 1: Write failing card and diagnostics tests**

```dart
test('decision card contains recommendation, comparison, evidence, and risk', () {
  final s = File('lib/widgets/ai_assistant_panel_content.dart').readAsStringSync();
  expect(s, contains('Recommendation'));
  expect(s, contains('Alternatives considered'));
  expect(s, contains('Evidence'));
  expect(s, contains('Remaining risk'));
});
test('agent diagnostics exclude private reasoning', () {
  final s = File('lib/widgets/ai_assistant_panel_loop.dart').readAsStringSync();
  expect(s, contains('decision_route='));
  expect(s, contains('decision_fallback='));
  expect(s, isNot(contains('private_reasoning')));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: FAIL because no decision card exists.

- [ ] **Step 3: Implement summary UI and logs**

After a deep run exits, append a summary card containing structured recommendation, alternatives, real evidence, and residual risk. Fallback displays `Recommendation unavailable — completed with the standard agent path` and the cause. `_logAgent` records route, phase counts, focus status, verification status, recovery count, and fallback category only.

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/widgets/ai_assistant_panel_selection_test.dart`

Expected: PASS.

Commit: `git add lib/widgets/ai_assistant_panel_models.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_panel_loop.dart test/widgets/ai_assistant_panel_selection_test.dart && git commit -m "feat(agent): show verified decision summaries"`

### Task 8: Add 27B calibration suite and complete regression check

**Files:**
- Create: `docs/agent-evals/adaptive-decision-suite.md`
- Modify: `test/services/agent_decision_policy_test.dart`
- Modify: `README.md`

**Interfaces:**
- Evaluation records task ID, expected route, completion, verification pass, model/tool calls, latency, tokens, safety result, and failure category.

- [ ] **Step 1: Write failing fixed-fixture test**

```dart
test('evaluation fixture routes remain stable', () {
  for (final fixture in adaptiveDecisionFixtures) {
    expect(AgentDecisionPolicy.classify(fixture.task, enabled), fixture.route,
        reason: fixture.id);
  }
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/services/agent_decision_policy_test.dart`

Expected: FAIL because the fixture matrix does not exist.

- [ ] **Step 3: Add evaluation protocol**

Document eight fixed tasks: direct inspection, code diagnosis, alternative implementation, destructive confirmation, current lookup, tool-failure recovery, incomplete-evidence recommendation, and long maintenance. Compare baseline, adaptive without focus, and adaptive with focus for each 27B model under identical host state. Promote only if verification-adjusted completion improves without safety regression; record cost and rollback setting. Link the protocol from the Agent section in `README.md`.

- [ ] **Step 4: Run focused and full verification**

Run: `flutter test test/services/agent_decision_policy_test.dart test/services/agent_deliberation_test.dart test/services/agent_tool_registry_test.dart test/services/llm_service_test.dart test/models/agent_config_test.dart test/widgets/ai_assistant_panel_selection_test.dart`

Expected: PASS.

Run: `flutter test`

Expected: PASS with no analyzer failures.

- [ ] **Step 5: Commit calibration assets**

Commit: `git add docs/agent-evals/adaptive-decision-suite.md README.md test/services/agent_decision_policy_test.dart && git commit -m "docs(agent): add adaptive decision evaluation suite"`

## Plan self-review

- **Spec coverage:** Tasks 1–2 cover routing and model defaults; Tasks 3–5 cover near-message guidance, tool focus, planning, and critique; Task 6 covers evidence verification/recovery; Task 7 covers user-facing recommendation/comparison/evidence/risk; Task 8 covers model calibration.
- **Safety:** Tool-free phases receive an empty native-tool list, current execution gates are unmodified, and focused calls retain core tools.
- **Compatibility:** New settings/API are optional and default off; fast path preserves existing cached prompt, stream loop, and tool registry.
- **Type consistency:** `AgentDecisionSettings` is persisted; `AgentDecisionRun` is per-task; `AgentRequestProfile` scopes provider requests; `AgentDecisionSummary` is display-only.
