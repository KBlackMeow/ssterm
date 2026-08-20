import 'agent_tool_contract.dart';
import '../models/mcp_server_config.dart';

/// The single source of truth for tools SSTerm can expose to an LLM.
///
/// Provider adapters translate these definitions to their native API shapes;
/// legacy models continue to receive the existing textual protocol separately.
class AgentToolRegistry {
  final List<AgentToolDefinition> definitions;
  final Map<String, McpTool> _mcpToolsByNativeName;

  AgentToolRegistry._(this.definitions, this._mcpToolsByNativeName);

  List<String> get names => definitions.map((tool) => tool.name).toList();

  AgentToolDefinition? byName(String name) {
    for (final tool in definitions) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  /// Restricts a first native-tool request to a focused subset. Shell and a
  /// structured question remain available so the Agent can always take a safe
  /// next step or ask for missing authority.
  AgentToolRegistry limitedTo(Set<String> allowedNames) {
    const required = {'bash', 'ask_user_question'};
    final allowed = {...required, ...allowedNames};
    return AgentToolRegistry._(
      List.unmodifiable(
        definitions.where((definition) => allowed.contains(definition.name)),
      ),
      _mcpToolsByNativeName,
    );
  }

  /// Converts a provider-visible MCP function call back to the canonical
  /// bridge shape already understood by the agent executor.
  AgentToolCall normalizeToolCall(AgentToolCall call) {
    final mcpTool = _mcpToolsByNativeName[call.name];
    if (mcpTool == null) return call;
    return AgentToolCall.fromRaw(
      id: call.id,
      name: 'mcp',
      providerName: call.providerName ?? call.name,
      providerArguments: call.providerArguments ?? call.arguments,
      arguments: {
        'server': mcpTool.serverId,
        'tool': mcpTool.name,
        'params': call.arguments,
      },
    )!;
  }

  factory AgentToolRegistry.build({
    bool webSearchEnabled = false,
    bool fileWriteEnabled = false,
    bool skillsEnabled = false,
    Iterable<McpTool> mcpTools = const [],
  }) {
    final mcpToolsByNativeName = <String, McpTool>{};
    final definitions = <AgentToolDefinition>[
      const AgentToolDefinition(
        name: 'bash',
        description:
            "Run one non-interactive command in the Agent's background shell.",
        parameters: {
          'command': AgentToolParameter.string(
            required: true,
            description: 'The shell command to run.',
          ),
          'reason': AgentToolParameter.string(
            required: true,
            description:
                'One short sentence explaining why this command is needed.',
          ),
          'risk_level': AgentToolParameter.stringEnum(
            required: true,
            values: ['normal', 'warning', 'dangerous'],
            description:
                'Command impact: normal (read-only/minimal), warning '
                '(local recoverable side effect), or dangerous '
                '(broad, irreversible, or high-cost impact).',
          ),
          'risk_reason': AgentToolParameter.string(
            required: true,
            description: 'One short sentence explaining the risk level.',
          ),
        },
      ),
      const AgentToolDefinition(
        name: 'ask_user_question',
        description:
            'Ask the user to choose between a small set of concrete options.',
        parameters: {
          'question': AgentToolParameter.string(required: true),
          'header': AgentToolParameter.string(required: true),
          'options': AgentToolParameter.array(
            required: true,
            items: {
              'type': 'object',
              'properties': {
                'label': {'type': 'string'},
                'description': {'type': 'string'},
              },
              'required': ['label', 'description'],
              'additionalProperties': false,
            },
          ),
        },
      ),
    ];

    if (webSearchEnabled) {
      definitions.add(
        const AgentToolDefinition(
          name: 'web_search',
          description: 'Search the public web for current information.',
          parameters: {'query': AgentToolParameter.string(required: true)},
        ),
      );
    }
    if (fileWriteEnabled) {
      definitions.addAll(const [
        AgentToolDefinition(
          name: 'write_file',
          description: 'Propose an atomic create or replacement of one file.',
          parameters: {
            'path': AgentToolParameter.string(required: true),
            'content': AgentToolParameter.string(required: true),
          },
        ),
        AgentToolDefinition(
          name: 'edit_file',
          description: 'Propose a precise replacement in one existing file.',
          parameters: {
            'path': AgentToolParameter.string(required: true),
            'old_string': AgentToolParameter.string(required: true),
            'new_string': AgentToolParameter.string(required: true),
            'replace_all': AgentToolParameter.boolean(),
          },
        ),
      ]);
    }
    if (skillsEnabled) {
      definitions.add(
        const AgentToolDefinition(
          name: 'use_skill',
          description: 'Load one installed agent skill by id.',
          parameters: {'skill_id': AgentToolParameter.string(required: true)},
        ),
      );
    }
    for (final mcpTool in mcpTools) {
      var nativeName = _nativeMcpName(mcpTool.qualifiedName);
      var collision = 2;
      while (mcpToolsByNativeName.containsKey(nativeName)) {
        nativeName = _withCollisionSuffix(
          _nativeMcpName(mcpTool.qualifiedName),
          collision++,
        );
      }
      mcpToolsByNativeName[nativeName] = mcpTool;
      definitions.add(
        AgentToolDefinition(
          name: nativeName,
          description: mcpTool.description.isEmpty
              ? 'Call ${mcpTool.name} on the ${mcpTool.serverName} MCP server.'
              : mcpTool.description,
          inputSchema: mcpTool.inputSchema,
          // MCP servers may return valid JSON Schema that does not satisfy
          // OpenAI's narrower strict-mode subset.
          strict: false,
        ),
      );
    }
    return AgentToolRegistry._(
      List.unmodifiable(definitions),
      Map.unmodifiable(mcpToolsByNativeName),
    );
  }

  static String _nativeMcpName(String qualifiedName) {
    final safe = qualifiedName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.length <= 64) return safe;
    final hash = _fnv1a32(qualifiedName).toRadixString(16).padLeft(8, '0');
    return '${safe.substring(0, 55)}_$hash';
  }

  static String _withCollisionSuffix(String base, int collision) {
    final suffix = '_$collision';
    final prefixLength = 64 - suffix.length;
    return '${base.substring(0, base.length.clamp(0, prefixLength))}$suffix';
  }

  static int _fnv1a32(String value) {
    var hash = 0x811c9dc5;
    for (final byte in value.codeUnits) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}
