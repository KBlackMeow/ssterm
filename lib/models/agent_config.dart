import 'mcp_server_config.dart';

// ── Provider ids ──────────────────────────────────────────────────────────

/// Agent provider 使用的 HTTP 请求协议。兼容端点必须显式选择协议，
/// 以保证工具调用的后续结果仍按原协议编码。
enum ProviderProtocol {
  openAiCompatible,
  anthropicCompatible,
  geminiNative,
  ollamaNative;

  String get id => switch (this) {
    ProviderProtocol.openAiCompatible => 'openai-compatible',
    ProviderProtocol.anthropicCompatible => 'anthropic-compatible',
    ProviderProtocol.geminiNative => 'gemini-native',
    ProviderProtocol.ollamaNative => 'ollama-native',
  };

  String get displayName => switch (this) {
    ProviderProtocol.openAiCompatible => 'OpenAI-compatible',
    ProviderProtocol.anthropicCompatible => 'Claude-compatible',
    ProviderProtocol.geminiNative => 'Gemini native',
    ProviderProtocol.ollamaNative => 'Ollama native',
  };

  static ProviderProtocol? tryFromId(String? id) {
    for (final protocol in ProviderProtocol.values) {
      if (protocol.id == id) return protocol;
    }
    return null;
  }
}

/// Agent 配置中可选择的模型服务商标识。该枚举用于配置序列化和 provider 路由；
/// 新增值时需同步处理显示名称、默认协议和请求构造。
enum LlmProvider {
  chatgpt,
  claude,
  gemini,
  deepseek,

  /// 本地 Ollama 服务。使用原生 `/api/chat` NDJSON 流接口，
  /// 以读取推理模型的 `thinking` 通道；默认不要求 API 密钥。
  ollama;

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
      case LlmProvider.ollama:
        return 'Ollama (local)';
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
      case LlmProvider.ollama:
        return 'ollama';
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
      case 'ollama':
        return LlmProvider.ollama;
      default:
        throw ArgumentError('Unknown provider: $id');
    }
  }
}

// ── Per-provider configuration ────────────────────────────────────────────

/// 一个模型服务商的连接配置。凭据通过独立的安全存储按 `id` 读取；
/// 本对象保存接口地址、模型标识及服务商特有参数，不应直接承载明文密钥。
class ProviderConfig {
  /// 稳定的 provider 标识，用于查找配置和对应的 API 密钥。
  final String id;
  /// 设置界面和 Agent 状态栏显示的服务商名称。
  String displayName;
  /// 请求协议类型，决定调用哪个 provider 适配器。
  final ProviderProtocol protocol;
  /// 是否允许该服务商出现在模型选择和请求路由中。
  bool enabled;
  /// API 根地址；内置 provider 有默认值，自定义 provider 需填写。
  String? baseUrl;
  /// 此服务商可供选择的模型 ID 列表。
  List<String> models;
  /// 模型 ID 到上下文窗口 token 上限的映射。
  Map<String, int> modelContextWindows;
  /// 模型 ID 到单次回复最大输出 token 数的映射。
  Map<String, int> modelMaxOutputTokens;

  /// 该 provider 是否需要用户配置 API 密钥。设置页据此显示密钥输入框，
  /// 请求发送前也据此检查凭据；未知 provider 默认按需要密钥处理。
  final bool requiresApiKey;

  ProviderConfig({
    required this.id,
    required this.displayName,
    this.protocol = ProviderProtocol.openAiCompatible,
    this.enabled = false,
    this.baseUrl,
    List<String>? models,
    Map<String, int>? modelContextWindows,
    Map<String, int>? modelMaxOutputTokens,
    this.requiresApiKey = true,
  }) : models = models ?? [],
       modelContextWindows = modelContextWindows ?? {},
       modelMaxOutputTokens = modelMaxOutputTokens ?? {};

  int maxOutputTokensFor(String model) => modelMaxOutputTokens[model] ?? 32768;

  factory ProviderConfig.chatgpt() => ProviderConfig(
    id: 'chatgpt',
    displayName: 'ChatGPT (OpenAI)',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'],
    modelContextWindows: {
      'gpt-5.6-sol': 128000,
      'gpt-5.6-terra': 128000,
      'gpt-5.6-luna': 128000,
    },
  );

  factory ProviderConfig.claude() => ProviderConfig(
    id: 'claude',
    displayName: 'Claude (Anthropic)',
    protocol: ProviderProtocol.anthropicCompatible,
    baseUrl: 'https://api.anthropic.com',
    models: ['claude-opus-4-8', 'claude-sonnet-4-6'],
    modelContextWindows: {
      'claude-opus-4-8': 200000,
      'claude-sonnet-4-6': 200000,
    },
  );

  factory ProviderConfig.gemini() => ProviderConfig(
    id: 'gemini',
    displayName: 'Gemini (Google)',
    protocol: ProviderProtocol.geminiNative,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    models: ['gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-3.5-flash-lite'],
    modelContextWindows: {
      'gemini-3.6-flash': 1048576,
      'gemini-3.5-flash': 1000000,
      'gemini-3.5-flash-lite': 1048576,
    },
  );

  factory ProviderConfig.deepseek() => ProviderConfig(
    id: 'deepseek',
    displayName: 'DeepSeek',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://api.deepseek.com',
    models: ['deepseek-v4-pro', 'deepseek-v4-flash'],
    modelContextWindows: {
      'deepseek-v4-pro': 1000000,
      'deepseek-v4-flash': 1000000,
    },
    modelMaxOutputTokens: {
      'deepseek-v4-pro': 32768,
      'deepseek-v4-flash': 32768,
    },
  );

  /// Local Ollama daemon (https://ollama.ai).  Default `baseUrl` is the
  /// loopback bind Ollama ships with; users running it on another machine
  /// (or inside Docker with a forwarded port) can override.
  ///
  /// Model list is intentionally EMPTY: Ollama only knows about whatever
  /// the user has `ollama pull`ed locally, and there's no canonical "right
  /// default" — `llama3.2` would be a hallucination on a box that only
  /// pulled `qwen2.5-coder`.  Better to render a blank dropdown that
  /// makes the user explicitly add their installed model names via the
  /// Settings UI's "+" affordance than to ship phantom defaults that
  /// fail with `model not found` on first dispatch.
  factory ProviderConfig.ollama() => ProviderConfig(
    id: 'ollama',
    displayName: 'Ollama (local)',
    protocol: ProviderProtocol.ollamaNative,
    baseUrl: 'http://localhost:11434',
    requiresApiKey: false,
    models: const [],
  );

  factory ProviderConfig.openrouter() => ProviderConfig(
    id: 'openrouter',
    displayName: 'OpenRouter',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://openrouter.ai/api/v1',
    models: [
      'openai/gpt-5.4',
      'openai/gpt-5.2-pro',
      'openai/gpt-5.2',
      'anthropic/claude-opus-5',
      'anthropic/claude-opus-5-fast',
      'anthropic/claude-sonnet-4.6',
      'deepseek/deepseek-v4-pro',
      'deepseek/deepseek-v4-flash',
      'moonshotai/kimi-k2.6',
      'qwen/qwen3.8-max',
      'qwen/qwen3.7-flash',
    ],
    modelContextWindows: {
      'openai/gpt-5.4': 1050000,
      'openai/gpt-5.2-pro': 400000,
      'openai/gpt-5.2': 400000,
      'anthropic/claude-opus-5': 1000000,
      'anthropic/claude-opus-5-fast': 1000000,
      'anthropic/claude-sonnet-4.6': 200000,
      'deepseek/deepseek-v4-pro': 1048576,
      'deepseek/deepseek-v4-flash': 1048576,
      'moonshotai/kimi-k2.6': 262144,
      'qwen/qwen3.8-max': 1000000,
      'qwen/qwen3.7-flash': 1000000,
    },
  );

  factory ProviderConfig.kimi() => ProviderConfig(
    id: 'kimi',
    displayName: 'Kimi (Moonshot AI)',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://api.moonshot.cn/v1',
    models: ['kimi-k2.6'],
    modelContextWindows: {'kimi-k2.6': 256000},
  );

  factory ProviderConfig.qwen() => ProviderConfig(
    id: 'qwen',
    displayName: 'Qwen (Alibaba Model Studio)',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    models: ['qwen3.7-plus'],
    modelContextWindows: {'qwen3.7-plus': 1000000},
  );

  factory ProviderConfig.glm() => ProviderConfig(
    id: 'glm',
    displayName: 'GLM (Zhipu AI)',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    models: ['glm-5.2', 'glm-5.1', 'glm-4.7'],
    modelContextWindows: {
      'glm-5.2': 1000000,
      'glm-5.1': 200000,
      'glm-4.7': 200000,
    },
  );

  factory ProviderConfig.mistral() => ProviderConfig(
    id: 'mistral',
    displayName: 'Mistral AI',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://api.mistral.ai/v1',
    models: ['devstral-latest', 'mistral-large-latest'],
    modelContextWindows: {
      'devstral-latest': 256000,
      'mistral-large-latest': 256000,
    },
  );

  factory ProviderConfig.siliconflow() => ProviderConfig(
    id: 'siliconflow',
    displayName: 'SiliconFlow',
    protocol: ProviderProtocol.openAiCompatible,
    baseUrl: 'https://api.siliconflow.cn/v1',
    models: ['deepseek-ai/DeepSeek-V3.2'],
    modelContextWindows: {'deepseek-ai/DeepSeek-V3.2': 128000},
  );

  factory ProviderConfig.minimax() => ProviderConfig(
    id: 'minimax',
    displayName: 'MiniMax',
    protocol: ProviderProtocol.anthropicCompatible,
    baseUrl: 'https://api.minimax.io/anthropic',
    models: ['MiniMax-M2.7', 'MiniMax-M2.7-highspeed'],
    modelContextWindows: {
      'MiniMax-M2.7': 204800,
      'MiniMax-M2.7-highspeed': 204800,
    },
  );

  factory ProviderConfig.openrouterAnthropic() => ProviderConfig(
    id: 'openrouter-anthropic',
    displayName: 'OpenRouter (Claude-compatible)',
    protocol: ProviderProtocol.anthropicCompatible,
    baseUrl: 'https://openrouter.ai/api',
    models: ['anthropic/claude-sonnet-4.6'],
    modelContextWindows: {'anthropic/claude-sonnet-4.6': 200000},
  );

  factory ProviderConfig.custom({
    required String id,
    required String displayName,
    required ProviderProtocol protocol,
    required String baseUrl,
    required List<String> models,
    Map<String, int>? modelContextWindows,
  }) {
    assert(
      protocol == ProviderProtocol.openAiCompatible ||
          protocol == ProviderProtocol.anthropicCompatible,
    );
    assert(baseUrl.isNotEmpty);
    assert(models.isNotEmpty);
    return ProviderConfig(
      id: id,
      displayName: displayName,
      protocol: protocol,
      baseUrl: baseUrl,
      models: models,
      modelContextWindows: modelContextWindows,
    );
  }

  static List<ProviderConfig> get builtIns => [
    ProviderConfig.chatgpt(),
    ProviderConfig.claude(),
    ProviderConfig.gemini(),
    ProviderConfig.deepseek(),
    ProviderConfig.ollama(),
    ProviderConfig.openrouter(),
    ProviderConfig.kimi(),
    ProviderConfig.qwen(),
    ProviderConfig.glm(),
    ProviderConfig.mistral(),
    ProviderConfig.siliconflow(),
    ProviderConfig.minimax(),
    ProviderConfig.openrouterAnthropic(),
  ];

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
      case 'ollama':
        return ProviderConfig.ollama();
      case 'openrouter':
        return ProviderConfig.openrouter();
      case 'kimi':
        return ProviderConfig.kimi();
      case 'qwen':
        return ProviderConfig.qwen();
      case 'glm':
        return ProviderConfig.glm();
      case 'mistral':
        return ProviderConfig.mistral();
      case 'siliconflow':
        return ProviderConfig.siliconflow();
      case 'minimax':
        return ProviderConfig.minimax();
      case 'openrouter-anthropic':
        return ProviderConfig.openrouterAnthropic();
      default:
        throw ArgumentError('Unknown provider: $id');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'protocol': protocol.id,
    'enabled': enabled,
    if (baseUrl != null) 'baseUrl': baseUrl,
    'models': models,
    if (modelContextWindows.isNotEmpty)
      'modelContextWindows': modelContextWindows,
    if (modelMaxOutputTokens.isNotEmpty)
      'modelMaxOutputTokens': modelMaxOutputTokens,
    // Persisted so a user-defined provider's "no-auth" flag round-trips.
    // Built-in providers don't strictly need it (the factory hard-codes
    // their `requiresApiKey`) but it keeps the JSON self-describing.
    'requiresApiKey': requiresApiKey,
  };

  /// Parses a single provider entry.  Returns `null` for malformed or
  /// unknown providers — the caller is expected to skip those rather than
  /// abort the entire config load (which would wipe the user's terminal
  /// settings, SFTP prefs, etc. via the catch-all in [AppConfig.load]).
  static ProviderConfig? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    String fallbackName;
    bool fallbackRequiresKey = true;
    ProviderProtocol fallbackProtocol = ProviderProtocol.openAiCompatible;
    try {
      final factory = ProviderConfig.fromId(id);
      fallbackName = factory.displayName;
      fallbackRequiresKey = factory.requiresApiKey;
      fallbackProtocol = factory.protocol;
    } catch (_) {
      // Unknown provider id (third-party, deprecated) — keep the entry
      // anyway so the user doesn't lose their stored API key list, but
      // pick a sensible display name and the safe "needs a key" default.
      fallbackName = id;
    }
    return ProviderConfig(
      id: id,
      displayName: json['displayName'] as String? ?? fallbackName,
      protocol:
          ProviderProtocol.tryFromId(json['protocol'] as String?) ??
          fallbackProtocol,
      enabled: json['enabled'] as bool? ?? false,
      baseUrl: json['baseUrl'] as String?,
      models:
          (json['models'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      modelContextWindows: _parseModelContextWindows(
        json['modelContextWindows'],
      ),
      modelMaxOutputTokens: _parseModelContextWindows(
        json['modelMaxOutputTokens'],
      ),
      requiresApiKey: json['requiresApiKey'] as bool? ?? fallbackRequiresKey,
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
    ProviderProtocol? protocol,
    bool? enabled,
    String? baseUrl,
    List<String>? models,
    Map<String, int>? modelContextWindows,
    Map<String, int>? modelMaxOutputTokens,
    bool? requiresApiKey,
  }) => ProviderConfig(
    id: id,
    displayName: displayName ?? this.displayName,
    protocol: protocol ?? this.protocol,
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    models: models ?? List.of(this.models),
    modelContextWindows:
        modelContextWindows ?? Map.of(this.modelContextWindows),
    modelMaxOutputTokens:
        modelMaxOutputTokens ?? Map.of(this.modelMaxOutputTokens),
    requiresApiKey: requiresApiKey ?? this.requiresApiKey,
  );
}

Map<String, int> _parseModelContextWindows(Object? raw) {
  if (raw is! Map) return {};
  final windows = <String, int>{};
  raw.forEach((key, value) {
    if (key is String && value is int && value > 0) windows[key] = value;
  });
  return windows;
}

// ── Dangerous-command blacklist ───────────────────────────────────────────

/// A user-defined dangerous-command rule.  Built-in rules live in code
/// (see `_builtinDangerRules` in `services/command_safety.dart`) — the
/// user only ever adds/edits CUSTOM patterns through Settings → Safety;
/// built-ins are toggled on/off via [DangerousCommandsPolicy.disabledBuiltins].
class CustomDangerPattern {
  /// 持久化用的稳定规则 ID，与正则内容分离；编辑正则不会改变规则身份或列表位置
  /// 。
  final String id;

  /// 规则命中时显示给用户的说明文字，用于审批卡和风险提示。
  String label;

  /// Dart 正则表达式文本。设置页保存前会编译校验；
  /// 运行期若仍无法编译则跳过此规则，避免单条坏规则中断 Agent。
  String pattern;

  /// 是否参与命令风险匹配；禁用后保留规则但不生效。
  bool enabled;

  CustomDangerPattern({
    required this.id,
    required this.label,
    required this.pattern,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'pattern': pattern,
    'enabled': enabled,
  };

  /// Returns null for malformed entries so the caller can skip them
  /// rather than abort the whole config load — same defensive style as
  /// [ProviderConfig.tryFromJson].
  static CustomDangerPattern? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final pattern = json['pattern'];
    if (id is! String || id.isEmpty) return null;
    if (pattern is! String || pattern.isEmpty) return null;
    return CustomDangerPattern(
      id: id,
      label: json['label'] as String? ?? id,
      pattern: pattern,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  CustomDangerPattern copyWith({
    String? label,
    String? pattern,
    bool? enabled,
  }) => CustomDangerPattern(
    id: id,
    label: label ?? this.label,
    pattern: pattern ?? this.pattern,
    enabled: enabled ?? this.enabled,
  );
}

/// 控制 Agent 命令的危险规则与审批行为。规则仅应用于 Agent 即将执行的命令；
/// 用户直接在终端输入的内容不经此策略拦截。
class DangerousCommandsPolicy {
  /// Agent 自动执行模式下，危险命令是否仍需用户逐条确认。
  bool agentConfirmEnabled;

  /// 用户明确关闭的内置规则 ID 集合。只保存关闭项可使新版本新增的内置规则默认生
  /// 效。
  Set<String> disabledBuiltins;

  /// 用户自定义的正则风险规则；无效表达式在匹配时会被跳过。
  List<CustomDangerPattern> customPatterns;

  DangerousCommandsPolicy({
    this.agentConfirmEnabled = true,
    Set<String>? disabledBuiltins,
    List<CustomDangerPattern>? customPatterns,
  }) : disabledBuiltins = disabledBuiltins ?? <String>{},
       customPatterns = customPatterns ?? <CustomDangerPattern>[];

  Map<String, dynamic> toJson() => {
    'agentConfirmEnabled': agentConfirmEnabled,
    // Sort so unrelated settings toggles don't reshuffle the JSON
    // diff — same rationale as `enabledSkills` above.
    if (disabledBuiltins.isNotEmpty)
      'disabledBuiltins': (disabledBuiltins.toList()..sort()),
    if (customPatterns.isNotEmpty)
      'customPatterns': customPatterns.map((p) => p.toJson()).toList(),
  };

  factory DangerousCommandsPolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null) return DangerousCommandsPolicy();
    final patterns = <CustomDangerPattern>[];
    final rawPatterns = json['customPatterns'];
    if (rawPatterns is List) {
      for (final e in rawPatterns) {
        if (e is! Map<String, dynamic>) continue;
        final p = CustomDangerPattern.tryFromJson(e);
        if (p != null) patterns.add(p);
      }
    }
    Set<String> disabled = <String>{};
    final rawDisabled = json['disabledBuiltins'];
    if (rawDisabled is List) {
      disabled = rawDisabled.whereType<String>().toSet();
    }
    // `userConfirmEnabled` was an opt-in keystroke-gate toggle in
    // earlier versions; the gate has been removed, so any persisted
    // value is silently ignored.  Kept tolerant in fromJson so old
    // configs load without warnings.
    return DangerousCommandsPolicy(
      agentConfirmEnabled: json['agentConfirmEnabled'] as bool? ?? true,
      disabledBuiltins: disabled,
      customPatterns: patterns,
    );
  }

  DangerousCommandsPolicy copyWith({
    bool? agentConfirmEnabled,
    Set<String>? disabledBuiltins,
    List<CustomDangerPattern>? customPatterns,
  }) => DangerousCommandsPolicy(
    agentConfirmEnabled: agentConfirmEnabled ?? this.agentConfirmEnabled,
    disabledBuiltins: disabledBuiltins ?? Set.of(this.disabledBuiltins),
    customPatterns: customPatterns ?? List.of(this.customPatterns),
  );
}

// ── Top-level agent config ─────────────────────────────────────────────────

/// Agent 的持久化总配置，包括 provider 列表、默认模型、执行模式、工具开关、MCP
/// 服务和技能设置。读写格式由本类的 JSON 转换逻辑维护。
class AgentConfig {
  /// Provider id used by [ApiKeyStorage] for the Brave Search API key.
  /// We deliberately reuse the existing key-storage path (keychain +
  /// 0600-permissioned file) instead of inventing a parallel store —
  /// the only thing that distinguishes a search key from an LLM key
  /// downstream is the id we look it up by, and storing them side by
  /// side keeps backup/restore semantics consistent.
  ///
  /// Lives here (not in a hypothetical `WebSearchConfig`) because there
  /// is currently exactly one search provider and adding a sub-class
  /// just to hold one constant would be overkill.  When (if) a second
  /// provider arrives, lift this into its own enum/class.
  static const braveSearchKeyId = 'brave-search';

  /// 默认模型服务商 ID；为空时由当前可用 provider 选择默认值。
  String? defaultProvider;
  /// 默认模型 ID；为空时使用所选 provider 的首个可用模型。
  String? defaultModel;
  /// 已配置服务商列表，包含内置服务商和用户自定义端点。
  List<ProviderConfig> providers;

  /// Render assistant replies as full markdown (bold, lists, headings,
  /// code blocks) using `gpt_markdown`.  ON by default — the readability
  /// win (especially for code blocks, lists, and `**emphasis**`) is
  /// large enough that we accept the per-token re-parse cost.  Users
  /// who care about raw streaming throughput on very long replies can
  /// toggle it off in Settings.
  bool markdownEnabled;

  /// 是否向模型开放网页搜索工具。关闭时工具不会进入提示词；Brave 密钥单独存储，
  /// 关闭开关不会删除密钥。
  bool webSearchEnabled;

  /// 是否允许模型提出文件写入/编辑提案。开启只开放提案能力；
  /// 每个文件仍需用户在界面点击应用后才会写入磁盘。
  bool fileWriteEnabled;

  /// Agent 可用技能的白名单。`null` 表示启用所有已安装技能；
  /// 非空集合只启用列出的 ID；空集合表示全部禁用。
  Set<String>? enabledSkills;

  /// 危险命令规则和确认策略；始终非空，默认启用 Agent 命令确认。
  DangerousCommandsPolicy dangerousPolicy;

  /// 是否启用 MCP 工具接入。关闭时即使配置了服务器，
  /// 也不会连接服务器或向模型提供其工具。
  bool mcpEnabled;

  /// MCP 服务器配置列表；启动连接时还会跳过各自 `enabled` 为 `false` 的服务器。
  List<McpServerConfig> mcpServers;

  AgentConfig({
    this.defaultProvider,
    this.defaultModel,
    List<ProviderConfig>? providers,
    this.markdownEnabled = true,
    this.webSearchEnabled = false,
    this.fileWriteEnabled = true,
    this.enabledSkills,
    DangerousCommandsPolicy? dangerousPolicy,
    this.mcpEnabled = false,
    List<McpServerConfig>? mcpServers,
  }) : dangerousPolicy = dangerousPolicy ?? DangerousCommandsPolicy(),
       mcpServers = mcpServers ?? [],
       providers = providers ?? ProviderConfig.builtIns;

  /// 当前生效的 provider：优先返回 [defaultProvider] 指定且已启用的项，
  /// 否则返回首个启用项；没有启用项时为空。
  ProviderConfig? get current {
    if (defaultProvider != null) {
      final match = providers
          .where((p) => p.id == defaultProvider && p.enabled)
          .firstOrNull;
      if (match != null) return match;
    }
    return providers.where((p) => p.enabled).firstOrNull;
  }

  /// 当前 provider 实际使用的模型 ID。全局默认模型属于该 provider 时优先使用，
  /// 否则回退到模型列表首项；列表为空时返回空值。
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
    'webSearchEnabled': webSearchEnabled,
    'fileWriteEnabled': fileWriteEnabled,
    // Serialise as a sorted list so the JSON diff stays stable across
    // saves (toggling unrelated settings shouldn't reshuffle this).
    if (enabledSkills != null)
      'enabledSkills': (enabledSkills!.toList()..sort()),
    'dangerousPolicy': dangerousPolicy.toJson(),
    'mcpEnabled': mcpEnabled,
    if (mcpServers.isNotEmpty)
      'mcpServers': mcpServers.map((s) => s.toJson()).toList(),
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
        // Same philosophy as the models list above: a saved token value for
        // a built-in model is an explicit user override and must survive a
        // restart, so saved entries win over factory defaults.  Factory
        // defaults are only back-filled for models the user hasn't
        // configured, so code updates still refresh windows for new built-ins
        // while never silently discarding a value the user set in the UI.
        final savedContextWindows = Map<String, int>.of(
          provider.modelContextWindows,
        );
        provider.modelContextWindows
          ..clear()
          ..addAll(defaults.modelContextWindows)
          ..addAll(savedContextWindows);
        final savedMaxOutputTokens = Map<String, int>.of(
          provider.modelMaxOutputTokens,
        );
        provider.modelMaxOutputTokens
          ..clear()
          ..addAll(defaults.modelMaxOutputTokens)
          ..addAll(savedMaxOutputTokens);
      } catch (_) {
        // Unknown provider id — leave its model list untouched.
      }
    }
    // Back-fill any built-in provider that was added to the enum AFTER
    // this config file was first saved.  Without this, a user who saved
    // their settings before (say) Ollama was added would never see the
    // new provider in the Settings sheet — `fromJson` would faithfully
    // reload their 4-entry list and `AgentConfig.fromJson` wouldn't
    // know to append the newcomer.  Appending (vs prepending) keeps
    // the user's existing visual order intact.
    final presentIds = providers.map((p) => p.id).toSet();
    for (final builtin in ProviderConfig.builtIns) {
      if (presentIds.contains(builtin.id)) continue;
      try {
        providers.add(ProviderConfig.fromId(builtin.id));
      } catch (_) {
        // Shouldn't happen for enum values, but a defensive skip costs
        // nothing and matches the "never crash AppConfig.load" rule.
      }
    }
    Set<String>? parsedEnabledSkills;
    final rawEnabledSkills = json['enabledSkills'];
    if (rawEnabledSkills is List) {
      parsedEnabledSkills = rawEnabledSkills.whereType<String>().toSet();
    }
    // Defensive MCP server list parsing — skip malformed entries.
    final mcpServers = <McpServerConfig>[];
    final rawMcpServers = json['mcpServers'];
    if (rawMcpServers is List) {
      for (final e in rawMcpServers) {
        if (e is! Map<String, dynamic>) continue;
        final s = McpServerConfig.tryFromJson(e);
        if (s != null) mcpServers.add(s);
      }
    }
    return AgentConfig(
      defaultProvider: json['defaultProvider'] as String?,
      defaultModel: json['defaultModel'] as String?,
      providers: providers,
      // Defaults mirror the constructor: markdown + file-write ship ON
      // (the agent's reply formatting + skill output looks markedly worse
      // unrendered, and the file-write tool is gated by a per-write
      // "Apply" confirmation anyway, so the irreversibility risk that
      // originally kept this off is already mitigated UI-side).  Web
      // search stays OFF because it costs API tokens and needs a Brave
      // key the user must explicitly provide.
      markdownEnabled: json['markdownEnabled'] as bool? ?? true,
      webSearchEnabled: json['webSearchEnabled'] as bool? ?? false,
      fileWriteEnabled: json['fileWriteEnabled'] as bool? ?? true,
      enabledSkills: parsedEnabledSkills,
      // Missing key (old config) → DangerousCommandsPolicy() defaults
      // (agent confirm ON).  Existing users get the agent safety
      // net automatically on first launch.
      dangerousPolicy: DangerousCommandsPolicy.fromJson(
        json['dangerousPolicy'] as Map<String, dynamic>?,
      ),
      mcpEnabled: json['mcpEnabled'] as bool? ?? false,
      mcpServers: mcpServers,
    );
  }

  /// [resetEnabledSkills], when true, forces [enabledSkills] back to
  /// null (the "all enabled, including future additions" default).  We
  /// need this flag because Dart copyWith can't otherwise distinguish
  /// "caller didn't pass the field" from "caller passed null".
  AgentConfig copyWith({
    String? defaultProvider,
    String? defaultModel,
    bool resetDefaultModel = false,
    List<ProviderConfig>? providers,
    bool? markdownEnabled,
    bool? webSearchEnabled,
    bool? fileWriteEnabled,
    Set<String>? enabledSkills,
    bool resetEnabledSkills = false,
    DangerousCommandsPolicy? dangerousPolicy,
    bool? mcpEnabled,
    List<McpServerConfig>? mcpServers,
  }) => AgentConfig(
    defaultProvider: defaultProvider ?? this.defaultProvider,
    // Like [resetEnabledSkills]: copyWith can't tell "not passed" from
    // "passed null", so clearing the default model (when it is removed from
    // its provider) needs an explicit reset flag.
    defaultModel: resetDefaultModel
        ? null
        : (defaultModel ?? this.defaultModel),
    providers: providers ?? List.of(this.providers),
    markdownEnabled: markdownEnabled ?? this.markdownEnabled,
    webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
    fileWriteEnabled: fileWriteEnabled ?? this.fileWriteEnabled,
    enabledSkills: resetEnabledSkills
        ? null
        : (enabledSkills ?? this.enabledSkills),
    dangerousPolicy: dangerousPolicy ?? this.dangerousPolicy,
    mcpEnabled: mcpEnabled ?? this.mcpEnabled,
    mcpServers: mcpServers ?? List.of(this.mcpServers),
  );
}
