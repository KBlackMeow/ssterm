import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../models/mcp_server_config.dart';

/// Manages MCP (Model Context Protocol) server connections, tool discovery,
/// and tool invocation for the ssterm agent.
///
/// Follows the static-service pattern of [LlmService] and [SkillService].
/// Each configured [McpServerConfig] with `enabled: true` is connected at
/// [init] time; tools are discovered and cached.  The agent loop calls
/// [callTool] to invoke MCP tools and [allTools] to build the system prompt.
class McpService {
  McpService._();

  static final Map<String, _ServerEntry> _servers = {};
  static bool _initialized = false;

  /// Called whenever the set of available MCP tools changes (server
  /// connected, disconnected, or tools refreshed).  The host wires this
  /// up to invalidate the LLM system-prompt cache so the next turn
  /// picks up the new tool catalogue.
  static void Function()? onToolsChanged;

  // ── Public API ──────────────────────────────────────────────────────

  /// Connect to all enabled servers.  Safe to call multiple times;
  /// subsequent calls are no-ops.  Errors from individual server
  /// connections are logged and surfaced via [events]; they never
  /// prevent the app from launching.
  static Future<void> init(List<McpServerConfig> configs) async {
    if (_initialized) return;
    _initialized = true;
    for (final config in configs) {
      if (!config.enabled) continue;
      // Fire-and-forget per server so one slow connection doesn't
      // block the others or the app startup.
      unawaited(connect(config).catchError((_) {
        // Errors are already reported through _setError + the events
        // stream; nothing more to do here.
      }));
    }
  }

  /// Connect (or reconnect) a single server.  If an existing connection
  /// with the same [config.id] is already running it is disconnected first.
  static Future<void> connect(McpServerConfig config) async {
    await disconnect(config.id);

    final entry = _ServerEntry(config);
    _servers[config.id] = entry;

    try {
      await entry
          .connect()
          .timeout(Duration(seconds: config.connectionTimeoutSeconds));
    } catch (e) {
      entry._setError('Connection failed: $e');
      _emit(McpServiceEvent(
        kind: McpServiceEventKind.error,
        serverId: config.id,
        message: '$e',
      ));
      return;
    }

    // Discover tools.
    try {
      await entry
          .refreshTools()
          .timeout(Duration(seconds: config.connectionTimeoutSeconds));
    } catch (e) {
      entry._setError('Tool discovery failed: $e');
      _emit(McpServiceEvent(
        kind: McpServiceEventKind.error,
        serverId: config.id,
        message: 'Tool discovery: $e',
      ));
      return;
    }

    _emit(McpServiceEvent(
      kind: McpServiceEventKind.connected,
      serverId: config.id,
    ));
    _emit(McpServiceEvent(
      kind: McpServiceEventKind.toolsChanged,
      serverId: config.id,
    ));
    // ignore: avoid_print
    print('[mcp] connected ${config.id}: ${entry.tools.length} tools');
    for (final t in entry.tools) {
      // ignore: avoid_print
      print('[mcp]   ${t.qualifiedName} — ${t.description}');
    }
    onToolsChanged?.call();
  }

  /// Disconnect and remove a single server.
  static Future<void> disconnect(String id) async {
    final entry = _servers.remove(id);
    if (entry == null) return;
    await entry._dispose();
    _emit(McpServiceEvent(
      kind: McpServiceEventKind.disconnected,
      serverId: id,
    ));
    // ignore: avoid_print
    print('[mcp] disconnected $id');
    onToolsChanged?.call();
  }

  /// Disconnect all servers and release resources.  Call at app shutdown.
  static Future<void> shutdown() async {
    final ids = _servers.keys.toList();
    for (final id in ids) {
      await disconnect(id);
    }
    _initialized = false;
  }

  /// Re-discover tools for all connected servers.
  static Future<void> refreshAllTools() async {
    for (final entry in _servers.values) {
      if (!entry.isConnected) continue;
      try {
        await entry.refreshTools();
      } catch (_) {
        // Individual refresh failures are surfaced per-server; keep going.
      }
    }
    _emit(const McpServiceEvent(
      kind: McpServiceEventKind.toolsChanged,
      serverId: '*',
    ));
  }

  /// All tools from all connected servers, flattened.
  static List<McpTool> get allTools {
    final tools = <McpTool>[];
    for (final entry in _servers.values) {
      if (!entry.isConnected) continue;
      tools.addAll(entry.tools);
    }
    return tools;
  }

  /// Aggregate connected-server count for UI badges.
  static int get connectedCount =>
      _servers.values.where((e) => e.isConnected).length;

  /// Whether at least one server is connected and has tools available.
  static bool get hasConnectedServers =>
      _servers.values.any((e) => e.isConnected);

  /// Check if a specific server is connected.
  static bool isConnected(String serverId) {
    final entry = _servers[serverId];
    return entry?.isConnected ?? false;
  }

  /// Number of tools discovered from a given server, or 0.
  static int toolCount(String serverId) {
    final entry = _servers[serverId];
    return entry?.tools.length ?? 0;
  }

  /// Look up a tool by fully-qualified name.
  static McpTool? findTool(String serverId, String toolName) {
    final entry = _servers[serverId];
    if (entry == null || !entry.isConnected) return null;
    return entry.toolByName(toolName);
  }

  /// Invoke an MCP tool and return the result.
  ///
  /// All errors (connection lost, timeout, JSON-RPC protocol error,
  /// tool execution error) are returned as [McpToolResult] with
  /// [McpToolResult.isError] = true — this method never throws.
  static Future<McpToolResult> callTool({
    required String serverId,
    required String toolName,
    required Map<String, Object?> arguments,
  }) async {
    final entry = _servers[serverId];
    if (entry == null) {
      return McpToolResult.clientError(
        serverId: serverId,
        toolName: toolName,
        message: 'MCP server "$serverId" is not configured.',
      );
    }
    if (!entry.isConnected) {
      return McpToolResult.clientError(
        serverId: serverId,
        toolName: toolName,
        message:
            'MCP server "${entry.config.displayName}" is not connected (${entry._lastError ?? "unknown reason"}).',
      );
    }

    final client = entry._client;
    if (client == null) {
      return McpToolResult.clientError(
        serverId: serverId,
        toolName: toolName,
        message:
            'MCP server "${entry.config.displayName}" has no active client.',
      );
    }

    try {
      final result = await client
          .callTool(CallToolRequest(
            name: toolName,
            arguments: _safeArgs(arguments),
          ))
          .timeout(Duration(seconds: entry.config.toolCallTimeoutSeconds));

      return _convertResult(serverId, toolName, result);
    } on TimeoutException {
      return McpToolResult.clientError(
        serverId: serverId,
        toolName: toolName,
        message:
            'MCP tool call timed out after ${entry.config.toolCallTimeoutSeconds}s.',
      );
    } on McpError catch (e) {
      return McpToolResult.clientError(
        serverId: serverId,
        toolName: toolName,
        message: 'MCP error (${e.code}): ${e.message}',
      );
    } catch (e) {
      return McpToolResult.clientError(
        serverId: serverId,
        toolName: toolName,
        message: '$e',
      );
    }
  }

  /// Broadcast stream of server state changes for UI reactivity.
  static final StreamController<McpServiceEvent> _eventController =
      StreamController<McpServiceEvent>.broadcast();
  static Stream<McpServiceEvent> get events => _eventController.stream;

  static void _emit(McpServiceEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  // ── Internal helpers ────────────────────────────────────────────────

  /// Convert a mcp_dart [CallToolResult] to our own [McpToolResult].
  static McpToolResult _convertResult(
    String serverId,
    String toolName,
    CallToolResult result,
  ) {
    final blocks = <McpContentBlock>[];
    for (final content in result.content) {
      blocks.add(_convertContent(content));
    }
    return McpToolResult(
      serverId: serverId,
      toolName: toolName,
      content: blocks,
      isError: result.isError,
    );
  }

  static McpContentBlock _convertContent(Content content) {
    switch (content) {
      case TextContent(:final text):
        return McpContentBlock(type: 'text', text: text);
      case ImageContent(:final data, :final mimeType):
        return McpContentBlock(
          type: 'image',
          data: data,
          mimeType: mimeType,
        );
      case AudioContent(:final data, :final mimeType):
        return McpContentBlock(
          type: 'audio',
          data: data,
          mimeType: mimeType,
        );
      case EmbeddedResource(:final resource):
        final text =
            resource is TextResourceContents ? resource.text : null;
        final blob =
            resource is BlobResourceContents ? resource.blob : null;
        return McpContentBlock(
          type: 'resource',
          uri: resource.uri,
          mimeType: resource.mimeType,
          text: text,
          data: blob,
        );
      case ResourceLink(:final uri, :final name, :final mimeType):
        return McpContentBlock(
          type: 'resource_link',
          uri: uri,
          name: name,
          mimeType: mimeType,
        );
      default:
        return McpContentBlock(
          type: 'text',
          text: '(unsupported content type: ${content.runtimeType})',
        );
    }
  }

  /// Ensure arguments are a plain `Map<String, Object?>` suitable for
  /// JSON serialisation.  The mcp_dart API expects `Map<String, dynamic>`
  /// but we receive `Map<String, Object?>` from the ToolCall parser.
  static Map<String, dynamic> _safeArgs(Map<String, Object?> args) {
    try {
      return (jsonDecode(jsonEncode(args)) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }
}

// ── Internal per-server state ─────────────────────────────────────────

class _ServerEntry {
  final McpServerConfig config;
  McpClient? _client;
  List<McpTool> _tools = [];
  String? _lastError;
  bool _disposed = false;

  _ServerEntry(this.config);

  bool get isConnected => _client != null && _lastError == null;
  List<McpTool> get tools => List.unmodifiable(_tools);

  McpTool? toolByName(String name) {
    try {
      return _tools.firstWhere((t) => t.name == name);
    } catch (_) {
      return null;
    }
  }

  Future<void> connect() async {
    if (_disposed) return;
    _lastError = null;

    final client = McpClient(
      Implementation(
        name: 'ssterm',
        title: 'SSTerm',
        version: '1.7.1',
      ),
      options: const McpClientOptions(
        // Use stable mode: prefer latest spec version with legacy fallback.
        protocol: McpProtocol.stable,
      ),
    );

    final Transport transport;
    switch (config.transport) {
      case McpTransportType.stdio:
        if (config.command == null || config.command!.isEmpty) {
          throw ArgumentError('stdio transport requires a command');
        }
        transport = StdioClientTransport(
          StdioServerParameters(
            command: config.command!,
            args: config.args,
            environment:
                config.env?.map((k, v) => MapEntry(k, v)),
          ),
        );
        break;

      case McpTransportType.streamableHttp:
        if (config.url == null || config.url!.isEmpty) {
          throw ArgumentError('Streamable HTTP transport requires a URL');
        }
        final opts = StreamableHttpClientTransportOptions(
          requestInit: config.headers != null
              ? {'headers': config.headers}
              : null,
        );
        transport = StreamableHttpClientTransport(
          Uri.parse(config.url!),
          opts: opts,
        );
        break;
    }

    await client.connect(transport);
    _client = client;
  }

  Future<void> refreshTools() async {
    final client = _client;
    if (client == null) return;

    final result = await client.listTools();
    _tools = result.tools.map((t) {
      return McpTool(
        serverId: config.id,
        serverName: config.displayName,
        name: t.name,
        description: (t.description ?? '').trim(),
        inputSchema: t.inputSchema.toJson().cast<String, Object?>(),
      );
    }).toList();
  }

  void _setError(String message) {
    _lastError = message;
  }

  Future<void> _dispose() async {
    _disposed = true;
    try {
      await _client?.close();
    } catch (_) {
      // Best-effort cleanup.
    }
    _client = null;
    _tools = [];
  }
}
