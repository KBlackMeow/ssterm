/// Transport type for an MCP server connection.
enum McpTransportType {
  /// Launch the server as a subprocess and communicate over stdin/stdout
  /// with newline-delimited JSON-RPC 2.0 messages.
  stdio,

  /// Connect to a remote MCP server via Streamable HTTP (POST + SSE).
  streamableHttp,
}

/// Configuration for one MCP (Model Context Protocol) server.
///
/// Each server exposes tools that the agent can discover and call at
/// runtime.  Servers are user-configured in Settings → Agent → MCP.
class McpServerConfig {
  /// Stable user-chosen slug used as the server identifier in tool-call
  /// dispatch.  Must be unique across all configured servers.  Keep it
  /// short and descriptive (e.g. "github", "filesystem", "jira").
  final String id;

  /// Human-readable label shown in Settings and agent feedback cards.
  String displayName;

  /// When false the server is persisted but not connected at startup.
  bool enabled;

  /// Transport mechanism.
  McpTransportType transport;

  // ── stdio ──────────────────────────────────────────────────────────

  /// The command to launch the server subprocess (e.g. "npx", "uvx",
  /// "python").  Only meaningful when [transport] is [McpTransportType.stdio].
  String? command;

  /// Arguments passed to [command].  Only meaningful for stdio transport.
  List<String> args;

  /// Extra environment variables merged into the subprocess environment.
  Map<String, String>? env;

  // ── Streamable HTTP ────────────────────────────────────────────────

  /// The MCP endpoint URL (e.g. "http://localhost:3000/mcp").  Only
  /// meaningful when [transport] is [McpTransportType.streamableHttp].
  String? url;

  /// Optional HTTP headers sent with every request (e.g. an
  /// Authorization bearer token).
  Map<String, String>? headers;

  // ── Timeouts ───────────────────────────────────────────────────────

  /// Maximum time to wait for the transport to establish (subprocess
  /// spawn + initialize handshake or HTTP connect).  Default 30 s.
  int connectionTimeoutSeconds;

  /// Maximum time to wait for a single `tools/call` round-trip.
  /// Default 60 s.
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

  /// Returns null for malformed entries so the caller can skip them
  /// rather than abort the whole config load.
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

/// A tool discovered from an MCP server.
class McpTool {
  /// The [McpServerConfig.id] this tool belongs to.
  final String serverId;

  /// The server's [McpServerConfig.displayName] (cached at discovery time).
  final String serverName;

  /// Tool name as reported by the server.
  final String name;

  /// Human-readable description.  May be empty.
  final String description;

  /// JSON Schema for the tool's parameters (the `inputSchema` from the
  /// MCP `tools/list` response).  Always a Map; the client must not
  /// assume a particular JSON Schema dialect, though servers SHOULD
  /// output 2020-12 or draft-07.
  final Map<String, Object?> inputSchema;

  const McpTool({
    required this.serverId,
    required this.serverName,
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  /// Fully-qualified name for LLM tool-call dispatch:
  /// `mcp__<serverId>__<toolName>`.
  String get qualifiedName => 'mcp__${serverId}__$name';
}

/// Result of an MCP `tools/call` invocation.
class McpToolResult {
  final String serverId;
  final String toolName;
  final List<McpContentBlock> content;
  final bool isError;

  const McpToolResult({
    required this.serverId,
    required this.toolName,
    required this.content,
    this.isError = false,
  });

  /// Convenience constructor for a simple text result.
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

  /// Convenience constructor for an error result from the client side
  /// (connection lost, timeout, JSON-RPC protocol error).
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

  /// Concatenated text from all `text`-type content blocks.
  String get textContent => content
      .where((b) => b.type == 'text')
      .map((b) => b.text ?? '')
      .join('\n');
}

/// A single content block in an MCP tool result.
class McpContentBlock {
  /// One of: "text", "image", "audio", "resource_link", "resource".
  final String type;

  /// Present for type "text".
  final String? text;

  /// Base64-encoded data for type "image" / "audio".
  final String? data;

  /// MIME type for type "image" / "audio" / "resource" / "resource_link".
  final String? mimeType;

  /// URI for type "resource_link" or embedded "resource".
  final String? uri;

  /// Name for type "resource_link".
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

/// Event emitted by [McpService] to notify listeners of server state changes.
enum McpServiceEventKind {
  checking,
  connected,
  disconnected,
  toolsChanged,
  error,
}

class McpServiceEvent {
  final McpServiceEventKind kind;
  final String serverId;
  final String? message;

  const McpServiceEvent({
    required this.kind,
    required this.serverId,
    this.message,
  });
}
