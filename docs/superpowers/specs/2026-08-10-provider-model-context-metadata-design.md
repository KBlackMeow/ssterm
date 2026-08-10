# Provider Model Context Metadata Design

## Goal

Keep SSTerm's built-in model IDs and context-window budgets aligned with the
official data published by each configured provider. Model IDs sent to APIs
must remain exact; context size is separate internal metadata. DeepSeek
additionally uses a configurable 32K client-side maximum for
each response instead of the existing hard-coded 4K request limit.

## Source policy

- Use the documentation or model metadata published by the provider backing
  each SSTerm preset. For example, use DeepSeek documentation for the direct
  DeepSeek preset and OpenRouter data for the OpenRouter preset.
- Do not infer a context window from the same model served by another
  provider.
- If a provider does not publish a clear value, retain the existing value and
  record it as unverified rather than guessing.
- Custom providers and Ollama models without explicit metadata continue to use
  the existing conservative 32K fallback.

## Catalogue representation

`ProviderConfig.models` contains only API model IDs. Model names are displayed,
persisted, and sent without context or output-limit suffixes.

`ProviderConfig.modelContextWindows` maps the exact model ID to its documented
context-window token count. DeepSeek's current direct API catalogue remains:

```dart
models: ['deepseek-v4-pro', 'deepseek-v4-flash'],
modelContextWindows: {
  'deepseek-v4-pro': 1000000,
  'deepseek-v4-flash': 1000000,
},
modelMaxOutputTokens: {
  'deepseek-v4-pro': 32768,
  'deepseek-v4-flash': 32768,
},
```

The 32K value is an SSTerm client default, not a claim about DeepSeek's model
maximum. Context-window metadata and maximum-output metadata remain separate.

The retired `deepseek-chat` and `deepseek-reasoner` aliases are not restored to
the built-in catalogue.

## Audited built-in catalogue

The implementation uses the following audit results. `Change` means the
current value is contradicted by the provider's documentation. `Keep` means
the current value is supported. `Unverified` means the provider's public
documentation did not establish an exact value during this audit, so this
change must not invent a replacement.

| Provider preset | Model ID | Official context | Action |
| --- | --- | ---: | --- |
| DeepSeek | `deepseek-v4-pro` | 1,000,000 | Change 128,000 to 1,000,000 |
| DeepSeek | `deepseek-v4-flash` | 1,000,000 | Change 128,000 to 1,000,000 |
| Gemini | `gemini-3.6-flash` | 1,048,576 input | Change 128,000 to 1,048,576 |
| Gemini | `gemini-3.5-flash` | 1,000,000 | Change 128,000 to 1,000,000 |
| Gemini | `gemini-3.5-flash-lite` | 1,048,576 input | Change 128,000 to 1,048,576 |
| Qwen | `qwen3.7-plus` | 1,000,000 | Change 128,000 to 1,000,000 |
| GLM | `glm-5.2` | 1,000,000 | Keep |
| GLM | `glm-5.1` | 200,000 | Keep |
| GLM | `glm-4.7` | 200,000 | Keep |
| Mistral | `devstral-latest` | 256,000 | Keep |
| Mistral | `mistral-large-latest` | 256,000 | Keep |
| MiniMax | `MiniMax-M2.7` | 204,800 | Keep |
| MiniMax | `MiniMax-M2.7-highspeed` | 204,800 | Keep |

OpenRouter models use the context sizes published by OpenRouter rather than
their upstream labs. Their existing values remain unchanged unless the
OpenRouter model metadata contradicts them. The direct OpenAI, Anthropic,
Moonshot, and SiliconFlow entries remain unchanged in this implementation
because this audit did not find provider documentation that establishes a
different exact value for the precise model IDs currently in the catalogue.
They are explicitly unverified, not treated as confirmed.

The audit sources are:

- [DeepSeek Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing/)
  for both V4 IDs and their 1M context length.
- [Google's latest Gemini model guide](https://ai.google.dev/gemini-api/docs/latest-model)
  and [Gemini 3.5 Flash guide](https://ai.google.dev/gemini-api/docs/whats-new-gemini-3.5)
  for the three exact Gemini IDs and their 1M / 1,048,576-token limits.
- [Alibaba Model Studio's `qwen3.7-plus` model page](https://help.aliyun.com/zh/model-studio/qwen3-7-plus)
  for its 1,000,000-token context.
- [Zhipu's model overview](https://docs.bigmodel.cn/cn/guide/start/model-overview)
  for the GLM entries.
- [Mistral's context-window limitations](https://docs.mistral.ai/resources/known-limitations)
  for Devstral 2 and Mistral Large 3, which are served by the `-latest`
  aliases.
- [MiniMax's text-generation model table](https://platform.minimax.io/docs/guides/text-generation)
  for both M2.7 IDs.
- OpenRouter's own model pages or models metadata for OpenRouter presets, such
  as [DeepSeek V4 Pro](https://openrouter.ai/deepseek/deepseek-v4-pro).

## Existing configuration migration

When loading a saved built-in provider, SSTerm merges the latest built-in
models with user-added models. During that merge it must also refresh context
metadata for every current built-in model from the factory catalogue. This
prevents stale saved values such as DeepSeek's previous 128K entry from
surviving an application upgrade.

Models not present in the current built-in catalogue are treated as custom:
their model IDs and user-saved context values remain unchanged. Unknown custom
providers are left untouched.

## UI

Model selectors display only the exact model ID, for example
`deepseek-v4-pro`. Context and output limits remain internal configuration and
are not appended to model names.

## Request output limit

`ProviderConfig.modelMaxOutputTokens` maps exact model IDs to SSTerm's desired
per-response output cap. Provider requests use the selected model's configured
value and fall back to the existing 4,096-token cap when no value is present.
For direct DeepSeek V4 Pro and Flash, the request sends `max_tokens: 32768`.
Saved built-in values are refreshed using the same ownership rules as context
windows; custom model values remain unchanged.

## Verification

- Catalogue tests assert every verified built-in model's context value.
- A migration test loads a built-in provider with stale context metadata and
  confirms current built-in values are refreshed.
- The same migration test confirms custom model context metadata is preserved.
- Request tests assert DeepSeek sends `max_tokens: 32768` and an unconfigured
  model retains the 4,096 fallback.
- Provider request tests continue to assert that the exact model ID, without a
  display suffix, is sent to the API.
- A widget test confirms model selectors show the raw model ID.
