# Remove Agent1 and OSC 133 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Agent1/Agent2 with one background-executing Agent and remove OSC 133 from every shell while retaining OSC 7 cwd tracking.

**Architecture:** Promote the existing Agent2 background executor and per-tab cwd to the canonical Agent path, then delete the visible-terminal Agent1 executor. Simplify each shell bootstrap to emit only OSC 7 and reduce `OutputPipe` to terminal output flow plus cwd-cleaning consumers.

**Tech Stack:** Flutter/Dart, `flutter_pty`/ConPTY, `dartssh2`, Flutter test.

## Global Constraints

- No Agent command may write bytes to the visible terminal PTY.
- Unsupported local shells and disconnected SSH sessions return explicit results; there is no terminal fallback.
- OSC 7 cwd reporting remains enabled for local bash/zsh, WSL, PowerShell, and SSH sessions.
- OSC 133, PSReadLine Enter hooks, command-boundary parsing, and sentinel capture are removed.
- Historical `agent1` and `agent2` command-history records remain readable; new records use `agent`.
- Existing file tools, web search, risk classification, permissions, and cancellation behavior remain unchanged.

## File map

- `lib/services/local_shell_wrapper.dart`, `lib/services/powershell_shell_wrapper.dart`, `lib/services/ssh_connection.dart`: emit OSC 7 only.
- `lib/services/local_shell_discovery.dart`, `lib/app/main_local.dart`: rename the PowerShell wrapper capability to cwd integration and launch the smaller prelude.
- `lib/io/output_pipe.dart`: retain flow control; delete command-boundary capture.
- `lib/services/shell_integration.dart`, `lib/services/terminal_command_executor.dart`: delete after their consumers are removed.
- `lib/models/app_config.dart`, `lib/models/tab_model.dart`: canonical Agent configuration and per-tab state with legacy JSON migration.
- `lib/app/main_views.dart`, `lib/app/main_chrome.dart`, `lib/app/main_mobile.dart`, `lib/app/main_ssh.dart`: expose one Agent wired only to background execution.
- `lib/widgets/ai_assistant_panel*.dart`, `lib/services/llm_service_prompts.dart`, `lib/services/background_command_executor.dart`: remove Agent1/Agent2 and OSC 133 presentation language.
- Focused tests under `test/services`, `test/io`, `test/models`, and `test/widgets` lock down each migration.

---

### Task 1: Simplify local and PowerShell shell integration to OSC 7

**Files:**
- Modify: `test/services/local_shell_wrapper_test.dart`
- Modify: `test/services/powershell_shell_wrapper_test.dart`
- Modify: `test/services/local_shell_discovery_test.dart`
- Modify: `lib/services/local_shell_wrapper.dart`
- Modify: `lib/services/powershell_shell_wrapper.dart`
- Modify: `lib/services/local_shell_discovery.dart`
- Modify: `lib/app/main_local.dart`

**Interfaces:**
- Produces: `String buildInteractiveShellWrapper()` containing cwd hooks only.
- Produces: `String buildPowerShellOsc7Prelude()` containing a prompt-chain cwd hook only.
- Produces: `LocalShellOption.usePowerShellCwdWrapper` persisted as `usePowerShellCwdWrapper`, while reading legacy `usePowerShellWrapper`.

- [ ] **Step 1: Write failing wrapper tests**

Replace OSC 133-positive assertions with explicit absence assertions and rename the PowerShell API used by the test:

```dart
test('emits OSC 7 without OSC 133 hooks', () {
  expect(script, contains(']7;file://'));
  expect(script, isNot(contains(']133;')));
  expect(script, isNot(contains('__ssterm_osc133')));
  expect(script, isNot(contains('PS0=')));
});

setUpAll(() => script = buildPowerShellOsc7Prelude());

test('does not hook PSReadLine or emit OSC 133', () {
  expect(script, contains('file:///'));
  expect(script, isNot(contains('PSReadLine')));
  expect(script, isNot(contains('Set-PSReadLineKeyHandler')));
  expect(script, isNot(contains('133;')));
});
```

Add a discovery JSON migration assertion:

```dart
final restored = LocalShellOption.fromJson({
  'id': 'powershell',
  'displayName': 'Windows PowerShell',
  'executable': r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
  'usePowerShellWrapper': true,
})!;
expect(restored.usePowerShellCwdWrapper, isTrue);
expect(restored.toJson(), containsPair('usePowerShellCwdWrapper', true));
expect(restored.toJson().containsKey('usePowerShellWrapper'), isFalse);
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
flutter test test/services/local_shell_wrapper_test.dart test/services/powershell_shell_wrapper_test.dart test/services/local_shell_discovery_test.dart
```

Expected: compilation fails because `buildPowerShellOsc7Prelude` and `usePowerShellCwdWrapper` do not exist, while current wrappers still contain OSC 133.

- [ ] **Step 3: Implement OSC 7-only wrappers**

Reduce zsh to `precmd_functions+=(__ssterm_cwd)` with duplicate protection, reduce bash to a `PROMPT_COMMAND` cwd hook, and retain the existing profile loading. Replace the PowerShell body with:

```dart
String buildPowerShellOsc7Prelude() => r'''
$script:SstmPrevPrompt = if (Test-Path Function:\prompt) { $function:prompt } else { $null }
function global:prompt {
  $sstmCwd = $PWD.ProviderPath -replace '\\', '/'
  [Console]::Out.Write([char]27 + ']7;file:///' + $sstmCwd + [char]27 + '\')
  if ($script:SstmPrevPrompt) { & $script:SstmPrevPrompt } else { "PS $($PWD.Path)> " }
}
''';
```

Rename the discovery field and launch guard to `usePowerShellCwdWrapper`, accept the old JSON key as a fallback, and call `buildPowerShellOsc7Prelude()` from `main_local.dart`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all tests pass and no wrapper assertion finds OSC 133.

- [ ] **Step 5: Commit**

```bash
git add lib/services/local_shell_wrapper.dart lib/services/powershell_shell_wrapper.dart lib/services/local_shell_discovery.dart lib/app/main_local.dart test/services/local_shell_wrapper_test.dart test/services/powershell_shell_wrapper_test.dart test/services/local_shell_discovery_test.dart
git commit -m "refactor: keep only OSC 7 in local shells"
```

### Task 2: Remove OSC 133 from SSH and WSL bootstrap paths

**Files:**
- Create: `test/services/ssh_shell_bootstrap_source_test.dart`
- Modify: `lib/services/ssh_connection.dart`
- Modify: `lib/services/local_shell_discovery.dart`
- Modify: `lib/app/main_chrome.dart`

**Interfaces:**
- Consumes: `buildInteractiveShellWrapper()` from Task 1 for launcher-backed WSL.
- Produces: interactive SSH bootstrap text containing OSC 7 and no OSC 133.

- [ ] **Step 1: Write the failing SSH/WSL absence test**

```dart
import 'dart:io';

test('SSH bootstrap reports cwd without OSC 133', () {
  final script = File('lib/services/ssh_connection.dart').readAsStringSync();
  expect(script, contains(']7;file://'));
  expect(script, isNot(contains(']133;')));
  expect(script, isNot(contains('__ssterm_osc133')));
});

test('WSL launcher wrapper has no OSC 133', () {
  expect(buildInteractiveShellWrapper(), isNot(contains(']133;')));
});
```

- [ ] **Step 2: Run tests and verify RED**

Run `flutter test test/services/ssh_shell_bootstrap_source_test.dart test/services/local_shell_wrapper_test.dart`.
Expected: SSH bootstrap assertion fails on `]133;C`/`]133;D`.

- [ ] **Step 3: Delete SSH preexec/precmd hooks**

Keep `__ssterm_cwd`, profile sourcing, and cwd hook installation. Remove `__ssterm_osc133_preexec`, `__ssterm_osc133_precmd`, `PS0`, exit-code preservation, and healing logic that exists only for OSC 133. Update WSL/menu comments to say “OSC 7 cwd bootstrap”.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Step 2 command. Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/services/ssh_connection.dart lib/services/local_shell_discovery.dart lib/app/main_chrome.dart test/services/ssh_shell_bootstrap_source_test.dart test/services/local_shell_wrapper_test.dart
git commit -m "refactor: remove OSC 133 from remote shells"
```

### Task 3: Promote Agent configuration, tab state, and history identity

**Files:**
- Create: `test/models/app_config_test.dart`
- Modify: `test/services/command_execution_history_test.dart`
- Modify: `lib/models/app_config.dart`
- Modify: `lib/models/tab_model.dart`
- Modify: `lib/services/command_execution_history.dart`
- Modify: `lib/app/main_local.dart`
- Modify: `lib/app/main_ssh.dart`

**Interfaces:**
- Produces: `AppConfig.agentPosition`, `AppConfig.agentSize`.
- Produces: `_Tab.agentPanelVisible`, `_Tab.agentCwd`.
- Produces: new command records with `agentId: 'agent'`.

- [ ] **Step 1: Add pure JSON seams to AppConfig and write migration tests**

Extract `AppConfig.fromJson(Map<String, dynamic>)` and `Map<String, dynamic> toJson()` so tests do not touch the real app-data directory. Add:

```dart
test('promotes legacy Agent2 layout to Agent layout', () {
  final config = AppConfig.fromJson({
    'agent2Position': 'right',
    'agent2Size': 420,
    'aiPosition': 'bottom',
    'aiSize': 300,
  });
  expect(config.agentPosition, AiPanelPosition.right);
  expect(config.agentSize, 420);
  expect(config.toJson(), containsPair('agentPosition', 'right'));
  expect(config.toJson().containsKey('agent2Position'), isFalse);
  expect(config.toJson().containsKey('aiPosition'), isFalse);
});

test('falls back to legacy Agent1 layout when Agent2 is absent', () {
  final config = AppConfig.fromJson({'aiPosition': 'bottom', 'aiSize': 300});
  expect(config.agentPosition, AiPanelPosition.bottom);
  expect(config.agentSize, 300);
});
```

- [ ] **Step 2: Run config tests and verify RED**

Run `flutter test test/models/app_config_test.dart`.
Expected: compilation fails because canonical fields and JSON seams do not exist.

- [ ] **Step 3: Implement canonical configuration and tab fields**

Load canonical keys first, then `agent2*`, then `ai*`; save only canonical keys. Rename `agent2PanelVisible`/`agent2Cwd` to `agentPanelVisible`/`agentCwd`, including initialization in local and SSH tab creation.

- [ ] **Step 4: Change history tests to canonical identity**

Update append tests to construct a complete `CommandExecutionRecord` with `agentId: 'agent'` and expect `agent`. Keep one decoding/inspection fixture containing `agent1` and `agent2` to demonstrate historical JSON lines remain ordinary readable records without normalization.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run `flutter test test/models/app_config_test.dart test/services/command_execution_history_test.dart`.
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/models/app_config.dart lib/models/tab_model.dart lib/services/command_execution_history.dart lib/app/main_local.dart lib/app/main_ssh.dart test/models/app_config_test.dart test/services/command_execution_history_test.dart
git commit -m "refactor: promote Agent2 state to Agent"
```

### Task 4: Replace both overlays with the single background Agent

**Files:**
- Modify: `test/widgets/ai_assistant_panel_selection_test.dart`
- Create: `test/app/agent_wiring_source_test.dart`
- Modify: `lib/app/main_views.dart`
- Modify: `lib/app/main_chrome.dart`
- Modify: `lib/app/main_mobile.dart`
- Modify: `lib/app/main_ssh.dart`
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Modify: `lib/widgets/ai_assistant_panel_widgets.dart`
- Modify: `lib/widgets/ai_assistant_panel_loop.dart`
- Modify: `lib/services/background_command_executor.dart`
- Modify: `lib/services/llm_service_prompts.dart`

**Interfaces:**
- Consumes: canonical config/tab fields from Task 3.
- Produces: one `AiAssistantOverlay` per terminal tab, with `onExecuteAsync` calling `_executeAgentCommand` and no terminal send/capture callbacks.

- [ ] **Step 1: Write a source-wiring regression test**

Until host wiring is injectable, use the established source as the correct integration seam:

```dart
test('main view owns one background-only Agent overlay', () {
  final source = File('lib/app/main_views.dart').readAsStringSync();
  expect('AiAssistantOverlay('.allMatches(source), hasLength(1));
  expect(source, contains('_executeAgentCommand'));
  expect(source, isNot(contains('_executeAndCapture')));
  expect(source, isNot(contains("'agent1'")));
  expect(source, isNot(contains("'agent2'")));
  expect(source, isNot(contains('onGetShellIntegrationActive:')));
});
```

- [ ] **Step 2: Run the wiring test and verify RED**

Run `flutter test test/app/agent_wiring_source_test.dart`.
Expected: fails because two overlays and both numbered identities remain.

- [ ] **Step 3: Remove Agent1 and promote the background overlay**

Delete the first overlay in `main_views.dart`; rename `_executeAgent2Command` to `_executeAgentCommand`; pass only background execution, canonical cwd, file adapter, config position/size, and `agentId: 'agent'`. Remove dock-collision logic because only one overlay remains.

Collapse tab-bar/mobile props and toggles to `agentPanelVisible`/`onToggleAgentPanel`, with tooltip `Toggle Agent`. Remove experimental/numeric badges and “send to terminal”, `Exec`, shell-integration status, and terminal-lock callbacks from the panel API and UI.

- [ ] **Step 4: Rename Agent2 language in services and prompts**

Replace user-visible errors such as:

```dart
'[ssterm background] Agent cannot execute on this tab.'
```

Rename comments and execution descriptions. Change the WSL process marker prefix from `ssterm-agent2-` to `ssterm-agent-`. Update the LLM prompt to describe direct background stdout/stderr and remove OSC 133 claims.

- [ ] **Step 5: Run widget and wiring tests and verify GREEN**

Run:

```bash
flutter test test/app/agent_wiring_source_test.dart test/widgets/ai_assistant_panel_selection_test.dart test/services/background_command_executor_test.dart test/services/llm_service_test.dart
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/app lib/widgets lib/services/background_command_executor.dart lib/services/llm_service_prompts.dart test/app/agent_wiring_source_test.dart test/widgets/ai_assistant_panel_selection_test.dart test/services/background_command_executor_test.dart test/services/llm_service_test.dart
git commit -m "feat: promote background execution to the only Agent"
```

### Task 5: Delete visible-terminal command capture and OSC 133 parsing

**Files:**
- Delete: `lib/services/terminal_command_executor.dart`
- Delete: `lib/services/shell_integration.dart`
- Delete: `test/services/terminal_command_executor_test.dart`
- Delete: OSC-specific tests from `test/io/output_pipe_test.dart`
- Modify: `lib/io/output_pipe.dart`
- Modify: `lib/app/main_ssh.dart`
- Modify: `lib/models/tab_model.dart`
- Modify: `lib/services/command_safety.dart`
- Modify: imports in `lib/main.dart`

**Interfaces:**
- Produces: `OutputPipe` with binding, transform, flow-control acknowledgement, dispose, and pause/release behavior only.
- Removes: `CommandExecutionTarget`, `TerminalCommandExecutor`, `hasOsc133`, `awaitNextCommand`, and OSC marker scanning.

- [ ] **Step 1: Add an OSC transparency regression test**

After deleting old capture expectations, add a test that proves `OutputPipe` no longer interprets OSC 133:

```dart
test('does not provide OSC 133 command capture APIs', () {
  final source = File('lib/io/output_pipe.dart').readAsStringSync();
  expect(source, isNot(contains('hasOsc133')));
  expect(source, isNot(contains('awaitNextCommand')));
  expect(source, isNot(contains('scanOsc133')));
});
```

- [ ] **Step 2: Run the output-pipe test and verify RED**

Run `flutter test test/io/output_pipe_test.dart`.
Expected: fails because the capture APIs remain.

- [ ] **Step 3: Remove capture code and consumers**

Delete OSC scan buffers, marker parsing, pending command completers, timeout/cancellation capture logic, and shell-integration imports from `OutputPipe`. Delete the two obsolete service files and their dedicated test. Remove `_activeCommandTarget`, `_executeAndCapture`, `_activePaneHasShellIntegration`, stale tab capture comments/state, and obsolete imports.

Update command-safety explanations that mention OSC 133 so they describe direct background-process constraints, retaining the actual safety classification behavior.

- [ ] **Step 4: Run focused tests and analyze**

Run:

```bash
flutter test test/io/output_pipe_test.dart test/services/command_safety_test.dart
flutter analyze
```

Expected: tests pass and analyzer reports no references to deleted APIs.

- [ ] **Step 5: Commit**

```bash
git add -A lib/io/output_pipe.dart lib/services/terminal_command_executor.dart lib/services/shell_integration.dart lib/app/main_ssh.dart lib/models/tab_model.dart lib/services/command_safety.dart lib/main.dart test/io/output_pipe_test.dart test/services/terminal_command_executor_test.dart
git commit -m "refactor: delete terminal command capture"
```

### Task 6: Repository-wide cleanup and verification

**Files:**
- Modify: production and test files reported by the exact forbidden-reference scan in Step 1.
- Modify: `RELEASE_NOTES.md`

**Interfaces:**
- Produces: no production references to Agent1, Agent2, OSC 133, or terminal command injection.

- [ ] **Step 1: Run forbidden-reference scans**

Run:

```bash
rg -n "Agent1|Agent2|agent1|agent2|OSC 133|osc133|]133;|TerminalCommandExecutor|awaitNextCommand|hasOsc133" lib test --glob '*.dart'
```

Expected: no matches except explicit legacy-key migration assertions for `agent1`, `agent2`, `agent2Position`, `agent2Size`, `aiPosition`, and `aiSize`.

- [ ] **Step 2: Clean residual naming and document the change**

Rename remaining runtime identifiers/copy to `Agent`, preserve only migration literals, and add release notes stating that Agent now executes in the background, visible-terminal injection was removed, OSC 7 remains, and OSC 133 was removed.

- [ ] **Step 3: Format and verify the complete change**

Run:

```bash
dart format lib test
git diff --check
flutter analyze
flutter test
```

Expected: formatting produces no unintended changes, diff check is clean, analyzer exits 0, and the full test suite exits 0.

- [ ] **Step 4: Review the final diff against the design**

Run:

```bash
git diff --stat d240ff8..HEAD
git diff d240ff8..HEAD -- lib test RELEASE_NOTES.md
```

Confirm one Agent overlay, background-only execution, OSC 7 retention, legacy config migration, canonical history identity, and absence of OSC 133.

- [ ] **Step 5: Commit**

```bash
git add lib test RELEASE_NOTES.md
git commit -m "chore: finish single Agent migration"
```
