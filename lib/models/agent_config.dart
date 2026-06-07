// ── Provider ids ──────────────────────────────────────────────────────────

enum LlmProvider {
  chatgpt,
  claude,
  gemini,
  deepseek;

  String get displayName {
    switch (this) {
      case LlmProvider.chatgpt:
        return 'ChatGPT (OpenAI)';
      case LlmProvider.claude:
        return 'Claude (Anthropic)';
      case LlmProvider.gemini:
        return 'Gemini (Google)';
      case LlmProvider.deepseek:
        return 'DeepSeek';
    }
  }

  String get id {
    switch (this) {
      case LlmProvider.chatgpt:
        return 'chatgpt';
      case LlmProvider.claude:
        return 'claude';
      case LlmProvider.gemini:
        return 'gemini';
      case LlmProvider.deepseek:
        return 'deepseek';
    }
  }

  static LlmProvider fromId(String id) {
    switch (id) {
      case 'chatgpt':
        return LlmProvider.chatgpt;
      case 'claude':
        return LlmProvider.claude;
      case 'gemini':
        return LlmProvider.gemini;
      case 'deepseek':
        return LlmProvider.deepseek;
      default:
        throw ArgumentError('Unknown provider: $id');
    }
  }
}

// ── Per-provider configuration ────────────────────────────────────────────

class ProviderConfig {
  final String id;
  String displayName;
  bool enabled;
  String? baseUrl;
  List<String> models;

  ProviderConfig({
    required this.id,
    required this.displayName,
    this.enabled = false,
    this.baseUrl,
    List<String>? models,
  }) : models = models ?? [];

  factory ProviderConfig.chatgpt() => ProviderConfig(
        id: 'chatgpt',
        displayName: 'ChatGPT (OpenAI)',
        baseUrl: 'https://api.openai.com/v1',
        models: [
          'gpt-5.5',
          'gpt-5.5-pro',
          'gpt-5.4-mini',
        ],
      );

  factory ProviderConfig.claude() => ProviderConfig(
        id: 'claude',
        displayName: 'Claude (Anthropic)',
        baseUrl: 'https://api.anthropic.com',
        models: [
          'claude-opus-4-8',
          'claude-sonnet-4-6',
        ],
      );

  factory ProviderConfig.gemini() => ProviderConfig(
        id: 'gemini',
        displayName: 'Gemini (Google)',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        models: [
          'gemini-3.1-pro-preview',
          'gemini-3-flash-preview',
        ],
      );

  factory ProviderConfig.deepseek() => ProviderConfig(
        id: 'deepseek',
        displayName: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com',
        models: [
          'deepseek-v4-pro',
          'deepseek-v4-flash',
        ],
      );

  static ProviderConfig fromId(String id) {
    switch (id) {
      case 'chatgpt':
        return ProviderConfig.chatgpt();
      case 'claude':
        return ProviderConfig.claude();
      case 'gemini':
        return ProviderConfig.gemini();
      case 'deepseek':
        return ProviderConfig.deepseek();
      default:
        throw ArgumentError('Unknown provider: $id');
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'enabled': enabled,
        if (baseUrl != null) 'baseUrl': baseUrl,
        'models': models,
      };

  /// Parses a single provider entry.  Returns `null` for malformed or
  /// unknown providers — the caller is expected to skip those rather than
  /// abort the entire config load (which would wipe the user's terminal
  /// settings, SFTP prefs, etc. via the catch-all in [AppConfig.load]).
  static ProviderConfig? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    String fallbackName;
    try {
      fallbackName = LlmProvider.fromId(id).displayName;
    } catch (_) {
      // Unknown provider id (third-party, deprecated) — keep the entry
      // anyway so the user doesn't lose their stored API key list, but
      // pick a sensible display name.
      fallbackName = id;
    }
    return ProviderConfig(
      id: id,
      displayName: json['displayName'] as String? ?? fallbackName,
      enabled: json['enabled'] as bool? ?? false,
      baseUrl: json['baseUrl'] as String?,
      models: (json['models'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  /// Throws on malformed input — kept for backwards compatibility.
  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    final p = tryFromJson(json);
    if (p == null) throw ArgumentError('Malformed provider entry: $json');
    return p;
  }

  ProviderConfig copyWith({
    String? displayName,
    bool? enabled,
    String? baseUrl,
    List<String>? models,
  }) =>
      ProviderConfig(
        id: id,
        displayName: displayName ?? this.displayName,
        enabled: enabled ?? this.enabled,
        baseUrl: baseUrl ?? this.baseUrl,
        models: models ?? List.of(this.models),
      );
}

// ── Top-level agent config ─────────────────────────────────────────────────

class AgentConfig {
  String? defaultProvider;
  String? defaultModel;
  List<ProviderConfig> providers;

  /// Render assistant replies as full markdown (bold, lists, headings,
  /// code blocks) using `gpt_markdown`.  Off by default; rendering cost
  /// scales with reply length and re-parses on every streamed token.
  bool markdownEnabled;

  AgentConfig({
    this.defaultProvider,
    this.defaultModel,
    List<ProviderConfig>? providers,
    this.markdownEnabled = false,
  }) : providers = providers ??
            [
              ProviderConfig.chatgpt(),
              ProviderConfig.claude(),
              ProviderConfig.gemini(),
              ProviderConfig.deepseek(),
            ];

  /// The currently enabled provider matching [defaultProvider], or the first
  /// enabled provider if none is explicitly selected.
  ProviderConfig? get current {
    if (defaultProvider != null) {
      final match =
          providers.where((p) => p.id == defaultProvider && p.enabled).firstOrNull;
      if (match != null) return match;
    }
    return providers.where((p) => p.enabled).firstOrNull;
  }

  /// Resolved model name: the global [defaultModel] if it belongs to the
  /// current provider's model list, or the first model from the current provider.
  String? get resolvedModel {
    final p = current;
    if (p == null) return null;
    if (defaultModel != null && p.models.contains(defaultModel)) {
      return defaultModel;
    }
    return p.models.isNotEmpty ? p.models.first : null;
  }

  Map<String, dynamic> toJson() => {
        if (defaultProvider != null) 'defaultProvider': defaultProvider,
        if (defaultModel != null) 'defaultModel': defaultModel,
        'providers': providers.map((p) => p.toJson()).toList(),
        'markdownEnabled': markdownEnabled,
      };

  factory AgentConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return AgentConfig();
    final list = json['providers'] as List<dynamic>?;
    if (list == null) return AgentConfig();
    // Skip malformed entries instead of throwing — a single bad provider
    // (manual edit, schema change, third-party id) must NOT take down the
    // entire AppConfig.load() and reset every other unrelated setting.
    final providers = <ProviderConfig>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final p = ProviderConfig.tryFromJson(e);
      if (p != null) providers.add(p);
    }
    // Merge factory-default models so the latest built-in models are
    // always present after a code update.  Models the user manually added
    // (or that were defaults in older versions) are kept as "custom".
    // Note: we cannot distinguish "old default" from "user-added", so old
    // factory defaults are preserved rather than removed — losing them
    // silently would surprise users who selected one as their default.
    for (final provider in providers) {
      try {
        final defaults = ProviderConfig.fromId(provider.id);
        final custom = provider.models
            .where((m) => !defaults.models.contains(m))
            .toList();
        provider.models
          ..clear()
          ..addAll([...defaults.models, ...custom]);
      } catch (_) {
        // Unknown provider id — leave its model list untouched.
      }
    }
    return AgentConfig(
      defaultProvider: json['defaultProvider'] as String?,
      defaultModel: json['defaultModel'] as String?,
      providers: providers,
      markdownEnabled: json['markdownEnabled'] as bool? ?? false,
    );
  }

  AgentConfig copyWith({
    String? defaultProvider,
    String? defaultModel,
    List<ProviderConfig>? providers,
    bool? markdownEnabled,
  }) =>
      AgentConfig(
        defaultProvider: defaultProvider ?? this.defaultProvider,
        defaultModel: defaultModel ?? this.defaultModel,
        providers: providers ?? List.of(this.providers),
        markdownEnabled: markdownEnabled ?? this.markdownEnabled,
      );
}
