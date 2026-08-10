# Provider Model Context Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct audited context windows, add DeepSeek's 32K client output cap, refresh stale built-in metadata, and display both values without changing API model IDs.

**Architecture:** Exact API IDs remain in `ProviderConfig.models`; context and output limits live in separate maps. Loading refreshes factory-owned metadata but preserves custom entries. Requests use the selected output limit with a 4K fallback, while settings derive labels without changing dropdown values.

**Tech Stack:** Dart, Flutter, `flutter_test`

## Global Constraints

- DeepSeek IDs remain `deepseek-v4-pro` and `deepseek-v4-flash`, each with exactly `1,000,000` tokens.
- Gemini windows are `1,048,576`, `1,000,000`, and `1,048,576` for 3.6 Flash, 3.5 Flash, and 3.5 Flash-Lite.
- Qwen `qwen3.7-plus` is exactly `1,000,000` tokens.
- Unverified provider values, custom metadata, and the unknown-model 32K fallback remain unchanged.
- Context suffixes are display-only and never enter persisted IDs or API payloads.
- DeepSeek V4 Pro and Flash send a client-side `max_tokens` value of `32,768`; models without configured output metadata retain the `4,096` fallback.

---

### Task 1: Correct audited catalogue metadata

**Files:**
- Modify: `test/services/llm_service_test.dart`
- Modify: `lib/models/agent_config.dart`

**Interfaces:**
- Consumes: the existing provider factories.
- Produces: corrected `modelContextWindows` used by context budgeting and UI labels.

- [ ] **Step 1: Write the failing test**

Add inside `group('Agent model catalogues', ...)`:

```dart
test('audited provider context windows match official specifications', () {
  expect(ProviderConfig.deepseek().modelContextWindows, {
    'deepseek-v4-pro': 1000000,
    'deepseek-v4-flash': 1000000,
  });
  expect(ProviderConfig.gemini().modelContextWindows, {
    'gemini-3.6-flash': 1048576,
    'gemini-3.5-flash': 1000000,
    'gemini-3.5-flash-lite': 1048576,
  });
  expect(
    ProviderConfig.qwen().modelContextWindows['qwen3.7-plus'],
    1000000,
  );
});
```

- [ ] **Step 2: Run it and verify RED**

```bash
flutter test test/services/llm_service_test.dart --plain-name 'audited provider context windows match official specifications'
```

Expected: FAIL because those factory values are currently `128000`.

- [ ] **Step 3: Apply the minimal corrections**

In `lib/models/agent_config.dart`, replace only the audited factory maps:

```dart
// Gemini
modelContextWindows: {
  'gemini-3.6-flash': 1048576,
  'gemini-3.5-flash': 1000000,
  'gemini-3.5-flash-lite': 1048576,
},

// DeepSeek
modelContextWindows: {
  'deepseek-v4-pro': 1000000,
  'deepseek-v4-flash': 1000000,
},

// Qwen
modelContextWindows: {'qwen3.7-plus': 1000000},
```

- [ ] **Step 4: Run the Step 2 command and verify GREEN**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/models/agent_config.dart test/services/llm_service_test.dart
git commit -m "fix: correct provider context windows"
```

### Task 2: Refresh stale built-in metadata when loading settings

**Files:**
- Modify: `test/services/llm_service_test.dart`
- Modify: `lib/models/agent_config.dart`

**Interfaces:**
- Consumes: `ProviderConfig.fromId(String)` and parsed saved metadata.
- Produces: current factory windows for built-in IDs while preserving custom model windows.

- [ ] **Step 1: Write the failing migration test**

```dart
test('reload refreshes built-in windows and preserves custom windows', () {
  final config = AgentConfig.fromJson({
    'providers': [
      {
        'id': 'deepseek',
        'models': ['deepseek-v4-pro', 'my-deepseek-model'],
        'modelContextWindows': {
          'deepseek-v4-pro': 128000,
          'my-deepseek-model': 64000,
        },
      },
    ],
  });
  final deepseek = config.providers.firstWhere((p) => p.id == 'deepseek');
  expect(deepseek.modelContextWindows['deepseek-v4-pro'], 1000000);
  expect(deepseek.modelContextWindows['deepseek-v4-flash'], 1000000);
  expect(deepseek.modelContextWindows['my-deepseek-model'], 64000);
});
```

- [ ] **Step 2: Run it and verify RED**

```bash
flutter test test/services/llm_service_test.dart --plain-name 'reload refreshes built-in windows and preserves custom windows'
```

Expected: FAIL because saved `128000` survives and the merged Flash model lacks metadata.

- [ ] **Step 3: Merge factory metadata after custom metadata**

In the existing built-in merge loop in `AgentConfig.fromJson`, immediately after rebuilding `provider.models`, add:

```dart
final customWindows = Map<String, int>.fromEntries(
  provider.modelContextWindows.entries.where(
    (entry) => !defaults.models.contains(entry.key),
  ),
);
provider.modelContextWindows
  ..clear()
  ..addAll(customWindows)
  ..addAll(defaults.modelContextWindows);
```

- [ ] **Step 4: Run focused and group tests**

```bash
flutter test test/services/llm_service_test.dart --plain-name 'reload refreshes built-in windows and preserves custom windows'
flutter test test/services/llm_service_test.dart --plain-name 'Agent model catalogues'
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/models/agent_config.dart test/services/llm_service_test.dart
git commit -m "fix: refresh built-in model metadata"
```

### Task 3: Render display-only context labels

**Files:**
- Modify: `test/views/settings_console_shell_test.dart`
- Modify: `lib/views/settings/settings_sheet_agent.dart`

**Interfaces:**
- Consumes: a raw model ID and its optional token count.
- Produces: `_modelLabel(String modelId, int? contextWindowTokens) -> String`, used only for settings presentation.

- [ ] **Step 1: Write the failing widget test**

Add this test to `test/views/settings_console_shell_test.dart`:

```dart
testWidgets('default model menu shows context without changing its value', (
  tester,
) async {
  var agent = AgentConfig(
    defaultProvider: 'deepseek',
    defaultModel: 'deepseek-v4-pro',
    providers: [ProviderConfig.deepseek().copyWith(enabled: true)],
  );
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsPage(
        settings: TerminalSettings(),
        onChanged: (_) {},
        agent: agent,
        onAgentChanged: (next) => agent = next,
      ),
    ),
  );

  await tester.tap(find.text('Agent'));
  await tester.pumpAndSettle();

  expect(find.text('deepseek-v4-pro [1M]'), findsOneWidget);
  expect(agent.defaultModel, 'deepseek-v4-pro');
});
```

- [ ] **Step 2: Run it and verify RED**

```bash
flutter test test/views/settings_console_shell_test.dart --plain-name 'default model menu shows context without changing its value'
```

Expected: FAIL because the dropdown renders only the raw ID.

- [ ] **Step 3: Add the formatter**

Add to `settings_sheet_agent.dart`:

```dart
String _modelLabel(String modelId, int? contextWindowTokens) {
  if (contextWindowTokens == null || contextWindowTokens <= 0) return modelId;
  if (contextWindowTokens >= 1000000) return '$modelId [1M]';
  if (contextWindowTokens % 1000 == 0) {
    return '$modelId [${contextWindowTokens ~/ 1000}K]';
  }
  return '$modelId [$contextWindowTokens]';
}
```

Use it for both dropdown hint and items, while retaining the raw value:

```dart
DropdownMenuItem(
  value: m,
  child: Text(_modelLabel(m, currentProvider.modelContextWindows[m])),
)
```

The hint must call the same formatter with `allModels.first` and its map value.

- [ ] **Step 4: Run focused tests**

```bash
flutter test test/views/settings_console_shell_test.dart --plain-name 'default model menu shows context without changing its value'
flutter test test/services/llm_service_test.dart --plain-name 'Agent model catalogues'
```

Expected: both PASS and the persisted default remains `deepseek-v4-pro`.

- [ ] **Step 5: Commit**

```bash
git add lib/views/settings/settings_sheet_agent.dart test/views/settings_console_shell_test.dart
git commit -m "feat: show model context labels"
```

### Task 4: Final verification

**Files:**
- Verify: `lib/models/agent_config.dart`
- Verify: `lib/views/settings/settings_sheet_agent.dart`
- Verify: `test/services/llm_service_test.dart`
- Verify: `test/views/settings_console_shell_test.dart`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: verification evidence only.

- [ ] **Step 1: Format changed Dart files**

```bash
dart format lib/models/agent_config.dart lib/views/settings/settings_sheet_agent.dart test/services/llm_service_test.dart test/views/settings_console_shell_test.dart
```

Expected: exit 0.

- [ ] **Step 2: Run focused suites**

```bash
flutter test test/services/llm_service_test.dart test/views/settings_console_shell_test.dart
```

Expected: all tests PASS.

- [ ] **Step 3: Run static analysis**

```bash
flutter analyze
```

Expected: exit 0 with no new issues.

- [ ] **Step 4: Inspect final state**

```bash
git diff HEAD~3 --check
git status --short
```

Expected: no whitespace errors and no unexpected changes.
