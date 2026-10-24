import 'agent_tool_contract.dart';
import 'agent_tool_registry.dart';

/// Checks a provider's complete tool batch before any side effect starts.
/// The panel supports batches of shell commands, MCP calls, or independent
/// bounded reads. Shell commands may share a batch with bounded reads; each
/// shell command still passes through its normal confirmation gate.
/// Tools that pause or replace the turn cannot share a batch.
class AgentToolBatch {
  AgentToolBatch._();

  static const readOnlyNames = {'read_output', 'read_file', 'grep_file'};
  static const maxReadOnlyCalls = 8;

  static List<AgentToolResult> completeResults(
    Iterable<AgentToolCall> calls,
    Iterable<AgentToolResult> produced, {
    String missingReason = 'no result was recorded',
  }) {
    final byId = <String, AgentToolResult>{};
    for (final result in produced) {
      byId.putIfAbsent(result.toolCallId, () => result);
    }
    return [
      for (final call in calls)
        byId[call.id] ??
            AgentToolResult(
              toolCallId: call.id,
              content: '[Tool call was not executed: $missingReason.]',
              isError: true,
            ),
    ];
  }

  static String? rejectionReason(
    List<AgentToolCall> calls,
    AgentToolRegistry registry, {
    String? finishReason,
  }) {
    if (calls.isEmpty) return null;
    if (const {
      'length',
      'max_tokens',
      'max_output_tokens',
    }.contains(finishReason?.toLowerCase())) {
      return 'The model response reached its output limit. Reissue the tool '
          'call with complete arguments.';
    }
    final ids = <String>{};
    for (final call in calls) {
      if (!ids.add(call.id)) return 'Tool call ids must be unique.';
      final definition = registry.byName(call.providerName ?? call.name);
      if (definition == null) {
        return 'Tool ${call.name} is unavailable. Choose an advertised tool.';
      }
      final error = _validateObject(
        call.providerArguments ?? call.arguments,
        definition.toJsonSchema(),
      );
      if (error != null) return '${call.name}: $error';
    }
    if (calls.length > 1) {
      final names = calls.map((call) => call.name).toSet();
      final readOnlyBatch =
          calls.length <= maxReadOnlyCalls &&
          names.every(readOnlyNames.contains);
      final shellAndReadBatch =
          calls.length <= maxReadOnlyCalls &&
          names.every((name) => name == 'bash' || readOnlyNames.contains(name));
      if (!readOnlyBatch &&
          !shellAndReadBatch &&
          (names.length != 1 ||
              (names.single != 'bash' && names.single != 'mcp'))) {
        return 'This combination of tools cannot execute in one turn. '
            'Issue one tool call at a time.';
      }
    }
    return null;
  }

  static String? _validateObject(
    Map<String, Object?> arguments,
    Map<String, Object?> schema,
  ) {
    final required = schema['required'];
    if (required is List) {
      for (final key in required) {
        if (key is String && !arguments.containsKey(key)) {
          return 'Missing required argument: $key.';
        }
      }
    }
    final properties = schema['properties'];
    if (properties is! Map) return null;
    for (final entry in arguments.entries) {
      final property = properties[entry.key];
      if (property == null) {
        if (schema['additionalProperties'] == false) {
          return 'Unknown argument: ${entry.key}.';
        }
        continue;
      }
      if (property is! Map) continue;
      final type = property['type'];
      final value = entry.value;
      final correctType = switch (type) {
        'string' => value is String,
        'boolean' => value is bool,
        'integer' => value is int,
        'number' => value is num,
        'array' => value is List,
        'object' => value is Map,
        _ => true,
      };
      if (!correctType) return 'Invalid type for ${entry.key}: expected $type.';
      final choices = property['enum'];
      if (choices is List && !choices.contains(value)) {
        return 'Invalid value for ${entry.key}.';
      }
      if (value is Map && type == 'object') {
        final nested = _validateObject(
          value.map((key, item) => MapEntry(key.toString(), item)),
          property.map((key, item) => MapEntry(key.toString(), item)),
        );
        if (nested != null) return '${entry.key}: $nested';
      }
      if (value is List && type == 'array') {
        final itemSchema = property['items'];
        if (itemSchema is Map) {
          for (var index = 0; index < value.length; index++) {
            final item = value[index];
            if (itemSchema['type'] == 'object' && item is Map) {
              final nested = _validateObject(
                item.map((key, value) => MapEntry(key.toString(), value)),
                itemSchema.map((key, value) => MapEntry(key.toString(), value)),
              );
              if (nested != null) return '${entry.key}[$index]: $nested';
            } else if (itemSchema['type'] == 'object') {
              return 'Invalid type for ${entry.key}[$index]: expected object.';
            }
          }
        }
      }
    }
    return null;
  }
}
