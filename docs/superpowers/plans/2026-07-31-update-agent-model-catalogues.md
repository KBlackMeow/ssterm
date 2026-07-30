# Update Agent Model Catalogues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh built-in cloud-provider model choices while preserving models a user has manually added to a saved agent configuration.

**Architecture:** Keep provider model identifiers in `ProviderConfig` factories. `AgentConfig.fromJson` already rebuilds each known provider list from its factory defaults and appends persisted entries absent from that default list; changing the factory lists therefore promotes current choices and preserves user-added models without a schema migration.

**Tech Stack:** Flutter, Dart, `flutter_test`.

## Global Constraints

- Use official provider model identifiers only.
- Do not add an Ollama default model: installed local models are machine-specific.
- Preserve custom saved model identifiers and provider order.
- Do not alter request routing, tool-call serialization, or API endpoints.

---

### Task 1: Lock down refreshed model defaults and saved-config merging

**Files:**
- Modify: `test/services/llm_service_test.dart`
- Modify: `lib/models/agent_config.dart`

**Interfaces:**
- Consumes: `ProviderConfig.chatgpt()`, `ProviderConfig.claude()`, `ProviderConfig.gemini()`, `ProviderConfig.deepseek()`, and `AgentConfig.fromJson(Map<String, dynamic>?)`.
- Produces: Current built-in choices for fresh configurations; reloaded configurations with current built-in choices followed by user-added choices.

- [ ] **Step 1: Write the failing model-catalogue tests**

  Add this group to `test/services/llm_service_test.dart` before the Ollama registration group:

  ```dart
  group('Agent model catalogues', () {
    test('new configurations expose the current cloud model catalogues', () {
      expect(ProviderConfig.chatgpt().models, equals([
        'gpt-5.6-sol',
        'gpt-5.6-terra',
        'gpt-5.6-luna',
      ]));
      expect(ProviderConfig.claude().models, equals([
        'claude-opus-4-8',
        'claude-sonnet-4-6',
      ]));
      expect(ProviderConfig.gemini().models, equals([
        'gemini-3.6-flash',
        'gemini-3.5-flash',
        'gemini-3.5-flash-lite',
      ]));
      expect(ProviderConfig.deepseek().models, equals([
        'deepseek-v4-pro',
        'deepseek-v4-flash',
      ]));
    });

    test('reloading a saved configuration promotes defaults and keeps custom models', () {
      final config = AgentConfig.fromJson({
        'providers': [
          {
            'id': 'chatgpt',
            'models': ['gpt-5.5', 'my-openai-proxy-model'],
          },
        ],
      });
      final chatgpt = config.providers.firstWhere((p) => p.id == 'chatgpt');
      expect(chatgpt.models, equals([
        'gpt-5.6-sol',
        'gpt-5.6-terra',
        'gpt-5.6-luna',
        'gpt-5.5',
        'my-openai-proxy-model',
      ]));
    });
  });
  ```

- [ ] **Step 2: Run the focused test to verify the old defaults fail it**

  Run: `flutter test test/services/llm_service_test.dart --plain-name "new configurations expose the current cloud model catalogues"`

  Expected: FAIL because the ChatGPT and Gemini factory lists still use superseded model identifiers.

- [ ] **Step 3: Replace only the affected factory defaults**

  In `lib/models/agent_config.dart`, replace the ChatGPT and Gemini lists with:

  ```dart
  models: [
    'gpt-5.6-sol',
    'gpt-5.6-terra',
    'gpt-5.6-luna',
  ],
  ```

  ```dart
  models: [
    'gemini-3.6-flash',
    'gemini-3.5-flash',
    'gemini-3.5-flash-lite',
  ],
  ```

  Leave the existing Claude, DeepSeek, and empty Ollama lists unchanged.

- [ ] **Step 4: Run the focused catalogue tests**

  Run: `flutter test test/services/llm_service_test.dart --plain-name "Agent model catalogues"`

  Expected: PASS; fresh defaults match the intended identifiers and saved custom values remain selectable.

- [ ] **Step 5: Run regression verification**

  Run: `flutter test test/services/llm_service_test.dart`

  Expected: PASS.

- [ ] **Step 6: Commit the verified catalogue update**

  ```bash
  git add lib/models/agent_config.dart test/services/llm_service_test.dart
  git commit -m "Update agent model catalogues"
  ```
