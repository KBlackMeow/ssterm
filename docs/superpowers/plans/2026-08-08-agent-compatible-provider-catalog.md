# Agent Compatible Provider Catalog Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Add popular OpenAI- and Anthropic-compatible Agent presets and user-created providers that explicitly select one protocol.

**Architecture:** Persist ProviderProtocol in ProviderConfig. Presets carry protocol, URL, current bundled model list and context windows. LLM dispatch selects an adapter by protocol; Settings creates a preset or validates a custom provider.

**Tech Stack:** Flutter/Dart, flutter_test, existing HttpClient/SSE adapters, ApiKeyStorage.

## Global Constraints

- A third-party provider is exactly OpenAI-compatible or Anthropic-compatible; never infer or auto-switch it.
- API keys remain in ApiKeyStorage, not Agent JSON.
- Built-in model lists update with SSTerm releases; Settings does not fetch them.
- Existing config, selected models, URLs and Agent terminal behavior stay compatible.

---

### Task 1: Protocol and provider catalogue

**Files:**
- Modify: lib/models/agent_config.dart
- Modify: test/services/llm_service_test.dart

**Interfaces:**
- Produces: enum ProviderProtocol { openAiCompatible, anthropicCompatible, geminiNative, ollamaNative }.
- Produces: ProviderConfig.protocol, ProviderConfig.custom, ProviderConfig.builtIns, and factories for OpenRouter, Kimi, Qwen, Groq, Mistral, SiliconFlow, Together, Fireworks, MiniMax and OpenRouter Anthropic.
- Consumed by: Tasks 2 and 3.

- [ ] **Step 1: Write failing data tests**

~~~dart
test('compatible presets expose protocol and current model', () {
  expect(ProviderConfig.kimi().protocol, ProviderProtocol.openAiCompatible);
  expect(ProviderConfig.kimi().baseUrl, 'https://api.moonshot.cn/v1');
  expect(ProviderConfig.kimi().models.first, 'kimi-k2.6');
  expect(ProviderConfig.minimax().protocol,
      ProviderProtocol.anthropicCompatible);
});

test('legacy unknown and custom config have deterministic protocols', () {
  expect(
    ProviderConfig.tryFromJson({'id': 'legacy-proxy'})!.protocol,
    ProviderProtocol.openAiCompatible,
  );
  final custom = ProviderConfig.custom(
    id: 'my-gateway', displayName: 'My gateway',
    protocol: ProviderProtocol.anthropicCompatible,
    baseUrl: 'https://example.test', models: ['model-a'],
  );
  expect(ProviderConfig.fromJson(custom.toJson()).protocol,
      ProviderProtocol.anthropicCompatible);
});
~~~

- [ ] **Step 2: Verify the test fails**

Run: flutter test test/services/llm_service_test.dart --plain-name "compatible presets expose protocol and current model"

Expected: FAIL because ProviderProtocol and preset factories are absent.

- [ ] **Step 3: Implement the catalogue**

~~~dart
enum ProviderProtocol {
  openAiCompatible, anthropicCompatible, geminiNative, ollamaNative;

  String get id => switch (this) {
    openAiCompatible => 'openai-compatible',
    anthropicCompatible => 'anthropic-compatible',
    geminiNative => 'gemini-native',
    ollamaNative => 'ollama-native',
  };
}
~~~

Add protocol to ProviderConfig constructor, JSON parsing/output and copyWith. Missing protocol resolves by original provider ID; unknown legacy IDs default to openAiCompatible. Add compatible factories with stable IDs, official URLs, latest bundled models and context windows. Add every factory to builtIns, and replace enum-only default/back-fill logic with builtIns. ProviderConfig.custom requires protocol, absolute URL and nonempty models.

- [ ] **Step 4: Verify and commit**

Run: dart format lib/models/agent_config.dart test/services/llm_service_test.dart && flutter test test/services/llm_service_test.dart

Expected: PASS.

~~~bash
git add lib/models/agent_config.dart test/services/llm_service_test.dart
git commit -m "feat: add compatible provider catalog"
~~~

### Task 2: Protocol-based LLM dispatch

**Files:**
- Modify: lib/services/llm_service.dart
- Modify: lib/services/llm_service_providers.dart
- Modify: test/services/llm_service_test.dart

**Interfaces:**
- Consumes: ProviderConfig.protocol.
- Produces: LlmService.providerKindFor and protocol-selected normal, compaction and stream calls.

- [ ] **Step 1: Write failing routing test**

~~~dart
test('compatible providers select their declared adapter', () {
  expect(LlmService.providerKindFor(ProviderConfig.kimi()), 'openai');
  expect(LlmService.providerKindFor(ProviderConfig.minimax()), 'anthropic');
  expect(LlmService.providerKindFor(ProviderConfig.custom(
    id: 'proxy', displayName: 'Proxy',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://proxy.test/v1', models: ['x'],
  )), 'openai');
});
~~~

- [ ] **Step 2: Verify the test fails**

Run: flutter test test/services/llm_service_test.dart --plain-name "compatible providers select their declared adapter"

Expected: FAIL because providerKindFor is absent.

- [ ] **Step 3: Implement protocol dispatch**

~~~dart
static String providerKindFor(ProviderConfig provider) => switch (provider.protocol) {
  ProviderProtocol.anthropicCompatible => 'anthropic',
  ProviderProtocol.geminiNative => 'gemini',
  ProviderProtocol.ollamaNative => 'ollama',
  ProviderProtocol.openAiCompatible => 'openai',
};
~~~

Use this selection in compactConversation, regular calls and streaming. nativeToolCalling is false only for ollamaNative. Keep DeepSeek-only options keyed by ID and preserve Gemini/Ollama adapters. Anthropic-compatible calls retain x-api-key and anthropic-version; no server-provider tool is sent.

- [ ] **Step 4: Verify and commit**

Run: flutter test test/services/llm_service_test.dart test/services/agent_provider_tools_test.dart

Expected: PASS.

~~~bash
git add lib/services/llm_service.dart lib/services/llm_service_providers.dart test/services/llm_service_test.dart
git commit -m "feat: route agent providers by protocol"
~~~

### Task 3: Settings provider creation

**Files:**
- Modify: lib/views/settings/settings_sheet.dart
- Modify: lib/views/settings/settings_sheet_agent.dart
- Modify: test/views/settings_console_shell_test.dart

**Interfaces:**
- Consumes: ProviderConfig.builtIns and ProviderConfig.custom.
- Produces: preset picker and custom-provider form.
- Consumed by: AgentConfig.providers and existing per-provider controllers.

- [ ] **Step 1: Write failing widget tests**

~~~dart
testWidgets('Agent settings adds Kimi preset', (tester) async {
  AgentConfig? changed;
  await tester.pumpWidget(testSettings(
    agent: AgentConfig(), onAgentChanged: (v) => changed = v,
  ));
  await openAgentTab(tester);
  await tester.tap(find.byKey(const Key('settings-add-provider')));
  await tester.tap(find.byKey(const Key('provider-preset-kimi')));
  expect(changed!.providers.map((p) => p.id), contains('kimi'));
});

testWidgets('custom provider requires protocol and model', (tester) async {
  await tester.pumpWidget(testSettings(agent: AgentConfig()));
  await openAgentTab(tester);
  await tester.tap(find.byKey(const Key('settings-add-provider')));
  await tester.tap(find.byKey(const Key('provider-custom')));
  await tester.tap(find.text('Save'));
  expect(find.text('Choose a protocol'), findsOneWidget);
  expect(find.text('Add at least one model'), findsOneWidget);
});
~~~

- [ ] **Step 2: Verify the test fails**

Run: flutter test test/views/settings_console_shell_test.dart --plain-name "Agent settings adds Kimi preset"

Expected: FAIL because the add-provider control is absent.

- [ ] **Step 3: Implement creation dialog**

Add settings-add-provider beside Providers. A private ProviderDialog lists unconfigured presets plus Custom. Custom requires a dropdown with only OpenAI-compatible and Anthropic-compatible, display name, absolute HTTP(S) URL and model. Generate a normalised custom ID and suffix collisions.

Before applying configuration, register key and URL controllers:

~~~dart
void _registerProvider(ProviderConfig provider) {
  _apiKeyControllers[provider.id] = TextEditingController();
  _baseUrlControllers[provider.id] =
      TextEditingController(text: provider.baseUrl ?? '');
  _apiKeyVisible[provider.id] = false;
  _agentApply(_agentConfig.copyWith(
    providers: [..._agentConfig.providers, provider],
  ));
}
~~~

Protocol is immutable after creation; render a compact protocol label in the existing provider card. Retain existing editable API key, URL and model controls.

- [ ] **Step 4: Verify and commit**

Run: dart format lib/views/settings/settings_sheet.dart lib/views/settings/settings_sheet_agent.dart test/views/settings_console_shell_test.dart && flutter test test/views/settings_console_shell_test.dart && flutter analyze

Expected: PASS; no analyzer errors or feature-specific warnings.

~~~bash
git add lib/views/settings/settings_sheet.dart lib/views/settings/settings_sheet_agent.dart test/views/settings_console_shell_test.dart
git commit -m "feat: add compatible provider settings"
~~~

### Task 4: Migration and full verification

**Files:**
- Modify: test/services/llm_service_test.dart
- Modify: test/views/settings_console_shell_test.dart

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: regression coverage for model promotion and custom protocol persistence.

- [ ] **Step 1: Add migration tests**

~~~dart
test('saved Kimi retains custom models when defaults are promoted', () {
  final config = AgentConfig.fromJson({
    'providers': [
      {'id': 'kimi', 'models': ['kimi-k2.5', 'private-kimi-proxy']},
    ],
  });
  final kimi = config.providers.firstWhere((p) => p.id == 'kimi');
  expect(kimi.models.first, 'kimi-k2.6');
  expect(kimi.models, containsAll(['kimi-k2.5', 'private-kimi-proxy']));
});
~~~

Also assert that custom Anthropic protocol round-trips and remains unchanged after its URL/model are edited.

- [ ] **Step 2: Run targeted and full verification**

Run: flutter test test/services/llm_service_test.dart test/views/settings_console_shell_test.dart && flutter test && flutter analyze && git diff --check

Expected: all tests pass; analyzer has no errors and no diagnostics introduced by this feature.

- [ ] **Step 3: Commit final coverage**

~~~bash
git add test/services/llm_service_test.dart test/views/settings_console_shell_test.dart
git commit -m "test: cover compatible provider catalog"
~~~

