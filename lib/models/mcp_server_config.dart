/// MCP 服务器的连接传输方式。
enum McpTransportType {
  /// 将服务器作为子进程启动，通过标准输入/输出交换逐行 JSON-RPC 2.0 消息。
  stdio,

  /// 通过 Streamable HTTP 连接远程服务器，使用 HTTP POST 及 SSE 接收响应。
  streamableHttp,
}

/// 一个 MCP 服务器的连接和超时配置。服务器可向 Agent 暴露工具，由设置页管理；
/// 传输类型决定使用子进程参数还是 HTTP 地址。
class McpServerConfig {
  /// 用户指定的稳定 ID，用于工具调用路由；同一配置中的服务器必须唯一。
  final String id;

  /// 设置页和 Agent 工具结果卡中展示的服务器名称。
  String displayName;

  /// 是否在 Agent 启动时连接该服务器；关闭时配置仍保留。
  bool enabled;

  /// 连接方式；决定使用 `command` 参数还是 `url`。
  McpTransportType transport;

  // ── stdio ──────────────────────────────────────────────────────────

  /// 启动 stdio 服务器的可执行命令，例如 `npx` 或 `python`；HTTP 传输时忽略。
  String? command;

  /// 传给 [command] 的参数列表；仅 stdio 传输使用。
  List<String> args;

  /// 启动子进程时额外设置的环境变量；仅 stdio 传输使用。
  Map<String, String>? env;

  // ── Streamable HTTP ────────────────────────────────────────────────

  /// Streamable HTTP MCP 服务端点；仅 HTTP 传输使用。
  String? url;

  /// 随每次 HTTP 请求发送的额外请求头，可用于认证；仅 HTTP 传输使用。
  Map<String, String>? headers;

  // ── Timeouts ───────────────────────────────────────────────────────

  /// 等待传输建立并完成初始化握手的最长时间，单位秒；默认 30 秒。
  int connectionTimeoutSeconds;

  /// 等待一次 `tools/call` 完成的最长时间，单位秒；默认 60 秒。
  int toolCallTimeoutSeconds;

  McpServerConfig({
    required this.id,
    required this.displayName,
    this.enabled = false,
    this.transport = McpTransportType.stdio,
    this.command,
    List<String>? args,
    this.env,
    this.url,
    this.headers,
    this.connectionTimeoutSeconds = 30,
    this.toolCallTimeoutSeconds = 60,
  }) : args = args ?? [];

  // ── Serialisation ──────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'enabled': enabled,
    'transport': transport.name,
    if (command != null) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env?.isNotEmpty == true) 'env': env,
    if (url != null) 'url': url,
    if (headers?.isNotEmpty == true) 'headers': headers,
    'connectionTimeoutSeconds': connectionTimeoutSeconds,
    'toolCallTimeoutSeconds': toolCallTimeoutSeconds,
  };

  /// 从配置映射构造服务器。字段缺失或格式错误时返回 `null`，
  /// 让调用方跳过单条坏配置而保留其他设置。
  static McpServerConfig? tryFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final displayName = json['displayName'] as String?;
    if (displayName == null || displayName.isEmpty) return null;

    McpTransportType transport;
    try {
      transport = McpTransportType.values.byName(
        json['transport'] as String? ?? 'stdio',
      );
    } catch (_) {
      transport = McpTransportType.stdio;
    }

    List<String> args = [];
    final rawArgs = json['args'];
    if (rawArgs is List) {
      args = rawArgs.whereType<String>().toList();
    }

    Map<String, String>? env;
    final rawEnv = json['env'];
    if (rawEnv is Map) {
      env = <String, String>{};
      for (final e in rawEnv.entries) {
        if (e.key is String && e.value is String) {
          env[e.key as String] = e.value as String;
        }
      }
      if (env.isEmpty) env = null;
    }

    Map<String, String>? headers;
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      headers = <String, String>{};
      for (final e in rawHeaders.entries) {
        if (e.key is String && e.value is String) {
          headers[e.key as String] = e.value as String;
        }
      }
      if (headers.isEmpty) headers = null;
    }

    return McpServerConfig(
      id: id,
      displayName: displayName,
      enabled: json['enabled'] as bool? ?? false,
      transport: transport,
      command: json['command'] as String?,
      args: args,
      env: env,
      url: json['url'] as String?,
      headers: headers,
      connectionTimeoutSeconds: json['connectionTimeoutSeconds'] as int? ?? 30,
      toolCallTimeoutSeconds: json['toolCallTimeoutSeconds'] as int? ?? 60,
    );
  }

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final c = tryFromJson(json);
    if (c == null) throw ArgumentError('Malformed MCP server entry: $json');
    return c;
  }

  McpServerConfig copyWith({
    String? displayName,
    bool? enabled,
    McpTransportType? transport,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? url,
    Map<String, String>? headers,
    int? connectionTimeoutSeconds,
    int? toolCallTimeoutSeconds,
  }) => McpServerConfig(
    id: id,
    displayName: displayName ?? this.displayName,
    enabled: enabled ?? this.enabled,
    transport: transport ?? this.transport,
    command: command ?? this.command,
    args: args ?? List.of(this.args),
    env: env ?? (this.env != null ? Map.of(this.env!) : null),
    url: url ?? this.url,
    headers: headers ?? (this.headers != null ? Map.of(this.headers!) : null),
    connectionTimeoutSeconds:
        connectionTimeoutSeconds ?? this.connectionTimeoutSeconds,
    toolCallTimeoutSeconds:
        toolCallTimeoutSeconds ?? this.toolCallTimeoutSeconds,
  );
}

/// 从 MCP 服务器发现的工具定义，保留模型调用所需的参数 schema 和来源信息。
class McpTool {
  /// 所属服务器的稳定 ID，用于把模型调用路由回正确的 MCP 连接。
  final String serverId;

  /// 发现工具时缓存的服务器显示名称，用于工具调用结果的来源标签。
  final String serverName;

  /// MCP 服务器报告的工具原始名称。
  final String name;

  /// 模型用于判断何时调用该工具的说明；服务器可返回空文本。
  final String description;

  /// 工具参数的 JSON Schema，即 MCP `tools/list` 返回的 `inputSchema`；
  /// 调用方不应假设具体 Schema 方言。
  final Map<String, Object?> inputSchema;

  const McpTool({
    required this.serverId,
    required this.serverName,
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  /// 发送给模型的唯一工具名，使用 `mcp__<serverId>__<toolName>`
  /// 避免不同服务器的同名工具冲突。
  String get qualifiedName => 'mcp__${serverId}__$name';
}

/// MCP `tools/call` 的结果，保留来源、内容块以及成功/错误状态。
class McpToolResult {
  /// 返回结果的服务器 ID，便于界面标注来源。
  final String serverId;
  /// 被调用的 MCP 工具名称。
  final String toolName;
  /// 按 MCP 内容块形式保留的文本、图片或资源结果。
  final List<McpContentBlock> content;
  /// 是否为工具执行错误；错误结果仍会传回 Agent 作为工具反馈。
  final bool isError;

  const McpToolResult({
    required this.serverId,
    required this.toolName,
    required this.content,
    this.isError = false,
  });

  /// 创建只包含一个文本内容块的结果。
  factory McpToolResult.text({
    required String serverId,
    required String toolName,
    required String text,
    bool isError = false,
  }) => McpToolResult(
    serverId: serverId,
    toolName: toolName,
    content: [McpContentBlock.text(text)],
    isError: isError,
  );

  /// 将客户端连接中断、超时或 JSON-RPC 错误转换为 MCP 错误结果。
  factory McpToolResult.clientError({
    required String serverId,
    required String toolName,
    required String message,
  }) => McpToolResult(
    serverId: serverId,
    toolName: toolName,
    content: [McpContentBlock.text(message)],
    isError: true,
  );

  /// 按原顺序拼接所有文本内容块；图片等非文本块不包含在结果中。
  String get textContent => content
      .where((b) => b.type == 'text')
      .map((b) => b.text ?? '')
      .join('\n');
}

/// MCP 工具结果中的一个内容块；可承载文本、图片、音频或资源引用。
class McpContentBlock {
  /// 内容种类，例如 `text`、`image`、`audio` 或资源链接。
  final String type;

  /// 文本内容块的文本值；其他类型通常为空。
  final String? text;

  /// 图片或音频内容的 Base64 数据。
  final String? data;

  /// 内容数据的 MIME 类型，用于显示或解码资源。
  final String? mimeType;

  /// 资源链接或嵌入资源的 URI。
  final String? uri;

  /// 资源链接的人类可读名称。
  final String? name;

  const McpContentBlock({
    required this.type,
    this.text,
    this.data,
    this.mimeType,
    this.uri,
    this.name,
  });

  factory McpContentBlock.text(String text) =>
      McpContentBlock(type: 'text', text: text);
}

/// MCP 服务状态事件；通知 Agent 和界面服务器连接或工具列表发生变化。
enum McpServiceEventKind {
  checking,
  connected,
  disconnected,
  toolsChanged,
  error,
}

/// MCP 服务层发出的状态事件，携带事件类型及受影响服务器/工具信息，供 Agent
/// 刷新可用工具列表或界面状态。
class McpServiceEvent {
  /// 当前变化的类别，例如正在连接、已连接、工具更新或发生错误。
  final McpServiceEventKind kind;
  /// 产生此事件的服务器 ID。
  final String serverId;
  /// 连接或发现工具失败时的附加说明；正常状态事件可为空。
  final String? message;

  const McpServiceEvent({
    required this.kind,
    required this.serverId,
    this.message,
  });
}
