import 'dart:collection';
import 'dart:convert';

import 'conversation_compactor.dart';

/// Provider-neutral description of one parameter accepted by an agent tool.
class AgentToolParameter {
  final String type;
  final String? description;
  final bool required;
  final Map<String, Object>? items;

  const AgentToolParameter._({
    required this.type,
    required this.required,
    this.description,
    this.items,
  });

  const AgentToolParameter.string({bool required = false, String? description})
    : this._(type: 'string', required: required, description: description);

  const AgentToolParameter.boolean({bool required = false, String? description})
    : this._(type: 'boolean', required: required, description: description);

  const AgentToolParameter.object({bool required = false, String? description})
    : this._(type: 'object', required: required, description: description);

  const AgentToolParameter.array({
    bool required = false,
    String? description,
    required Map<String, Object> items,
  }) : this._(
         type: 'array',
         required: required,
         description: description,
         items: items,
       );

  Map<String, Object> toJsonSchema() => {
    'type': type,
    'description': ?description,
    'items': ?items,
  };
}

/// Provider-neutral description of a tool exposed to the model.
class AgentToolDefinition {
  final String name;
  final String description;
  final Map<String, AgentToolParameter> parameters;
  final Map<String, Object?>? inputSchema;
  final bool strict;

  const AgentToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const {},
    this.inputSchema,
    this.strict = true,
  });

  Map<String, Object?> toJsonSchema() {
    final discoveredSchema = inputSchema;
    if (discoveredSchema != null) {
      return Map.unmodifiable(discoveredSchema);
    }
    final properties = <String, Object>{
      for (final entry in parameters.entries)
        entry.key: entry.value.toJsonSchema(),
    };
    final required = parameters.entries
        .where((entry) => entry.value.required)
        .map((entry) => entry.key)
        .toList(growable: false);
    return <String, Object>{
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    };
  }
}

/// A normalized native tool invocation returned by any provider.
class AgentToolCall {
  final String id;
  final String name;

  /// Original provider-visible function name.  MCP calls are normalized to
  /// the executor's `mcp` bridge name, while this preserves the concrete
  /// function name needed in the following provider-native tool result turn.
  final String? providerName;

  /// Original provider-visible arguments.  MCP execution uses a canonical
  /// bridge argument shape, while provider continuations must replay the
  /// arguments accepted by the concrete function schema.
  final Map<String, Object?>? providerArguments;
  final Map<String, Object?> arguments;

  const AgentToolCall._({
    required this.id,
    required this.name,
    this.providerName,
    this.providerArguments,
    required this.arguments,
  });

  /// Returns null when [arguments] cannot be decoded to a JSON object.
  static AgentToolCall? fromRaw({
    required String id,
    required String name,
    String? providerName,
    Map<String, Object?>? providerArguments,
    required Object? arguments,
  }) {
    if (id.trim().isEmpty || name.trim().isEmpty) return null;
    final parsed = _argumentsObject(arguments);
    if (parsed == null) return null;
    return AgentToolCall._(
      id: id,
      name: name,
      providerName: providerName,
      providerArguments: providerArguments == null
          ? null
          : Map.unmodifiable(providerArguments),
      arguments: Map.unmodifiable(parsed),
    );
  }

  /// Legacy transcript representation used while panel history is text-only.
  Map<String, dynamic> toLegacyJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };

  static Map<String, Object?>? _argumentsObject(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return null;
    }
  }
}

/// One native tool outcome, correlated to its original provider call id.
class AgentToolResult {
  final String toolCallId;
  final String content;
  final bool isError;

  const AgentToolResult({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });
}

/// Provider-neutral item retained in the agent conversation transcript.
///
/// Text remains role-based while tool calls and results stay structured until
/// a provider adapter serializes them for its native wire protocol.
class AgentConversationItem {
  final String? role;
  final String? content;
  final List<AgentToolCall> toolCalls;
  final List<AgentToolResult> toolResults;

  const AgentConversationItem._({
    this.role,
    this.content,
    this.toolCalls = const [],
    this.toolResults = const [],
  });

  const AgentConversationItem.text({
    required String role,
    required String content,
  }) : this._(role: role, content: content);

  AgentConversationItem.assistantToolCalls(
    Iterable<AgentToolCall> calls, {
    String? content,
  }) : this._(content: content, toolCalls: List.unmodifiable(calls));

  AgentConversationItem.toolResults(Iterable<AgentToolResult> results)
    : this._(toolResults: List.unmodifiable(results));
}

/// Transitional list wrapper that keeps existing panel call sites source
/// compatible while storing only typed conversation items.
class AgentConversationHistory extends ListBase<AgentConversationItem> {
  final List<AgentConversationItem> _items = [];

  @override
  int get length => _items.length;

  @override
  set length(int value) => _items.length = value;

  @override
  AgentConversationItem operator [](int index) => _items[index];

  @override
  void operator []=(int index, AgentConversationItem value) {
    _items[index] = value;
  }

  @override
  void add(Object? element) {
    if (element is AgentConversationItem) {
      _items.add(element);
      return;
    }
    if (element is Map) {
      final role = element['role'];
      final content = element['content'];
      if (role is String && content is String) {
        // Host-managed tools (file approval, skill loading, or a user choice)
        // still report through this legacy text path. When it immediately
        // follows native calls, it must be encoded as tool results instead.
        final precedingCalls = _items.isEmpty
            ? const <AgentToolCall>[]
            : _items.last.toolCalls;
        if (role == 'user' && precedingCalls.isNotEmpty) {
          _items.add(
            AgentConversationItem.toolResults([
              for (final call in precedingCalls)
                AgentToolResult(toolCallId: call.id, content: content),
            ]),
          );
          return;
        }
        _items.add(AgentConversationItem.text(role: role, content: content));
        return;
      }
    }
    throw ArgumentError.value(element, 'element', 'Expected conversation item');
  }

  /// Retains the newest complete transcript groups without splitting native
  /// assistant tool calls from their following tool-result item.
  void trimToMaxItems({required int maxItems, int pinnedItemCount = 0}) {
    if (maxItems < 0 || pinnedItemCount < 0) {
      throw ArgumentError('maxItems and pinnedItemCount must be non-negative');
    }
    if (_items.length <= maxItems) return;
    var pinned = pinnedItemCount.clamp(0, _items.length);
    // The historical "first user + first assistant" pin can end on a
    // native assistant tool call. Its result is mandatory in the next
    // provider request, so include it in the pinned head as well.
    if (pinned > 0 &&
        pinned < _items.length &&
        _items[pinned - 1].toolCalls.isNotEmpty &&
        _items[pinned].toolResults.isNotEmpty) {
      pinned++;
    }
    final available = maxItems - pinned;
    if (available <= 0) {
      _items.removeRange(pinned, _items.length);
      return;
    }

    var start = _items.length;
    var kept = 0;
    while (start > pinned) {
      var groupStart = start - 1;
      var groupSize = 1;
      if (_items[groupStart].toolResults.isNotEmpty &&
          groupStart > pinned &&
          _items[groupStart - 1].toolCalls.isNotEmpty) {
        groupStart--;
        groupSize = 2;
      }
      if (kept + groupSize > available) break;
      kept += groupSize;
      start = groupStart;
    }
    if (start > pinned) _items.removeRange(pinned, start);
  }

  String? get summaryContent {
    for (final item in _items) {
      final summary = ConversationCompactor.unwrap(item.content);
      if (summary != null) return summary;
    }
    return null;
  }

  bool needsCompaction({required int maxItems}) => _items.length > maxItems;

  List<AgentConversationItem> compactionCandidate({
    required int pinnedItemCount,
    required int recentItemCount,
  }) {
    final pinned = pinnedItemCount.clamp(0, _items.length);
    final start = _summaryIndexAfter(pinned);
    var end = _items.length;
    var kept = 0;
    while (end > start && kept < recentItemCount) {
      var groupStart = end - 1;
      var groupSize = 1;
      if (_items[groupStart].toolResults.isNotEmpty &&
          groupStart > start &&
          _items[groupStart - 1].toolCalls.isNotEmpty) {
        groupStart--;
        groupSize = 2;
      }
      if (kept + groupSize > recentItemCount) break;
      kept += groupSize;
      end = groupStart;
    }
    return List.unmodifiable(_items.sublist(start, end));
  }

  bool replaceWithSummary({
    required String summary,
    required int pinnedItemCount,
    required int recentItemCount,
  }) {
    final candidate = compactionCandidate(
      pinnedItemCount: pinnedItemCount,
      recentItemCount: recentItemCount,
    );
    if (candidate.isEmpty) return false;
    final start = _summaryIndexAfter(pinnedItemCount.clamp(0, _items.length));
    final end = start + candidate.length;
    _items.replaceRange(start, end, [
      AgentConversationItem.text(
        role: 'user',
        content: ConversationCompactor.wrap(summary),
      ),
    ]);
    return true;
  }

  int _summaryIndexAfter(int pinned) {
    if (pinned < _items.length &&
        ConversationCompactor.unwrap(_items[pinned].content) != null) {
      return pinned + 1;
    }
    return pinned;
  }
}
