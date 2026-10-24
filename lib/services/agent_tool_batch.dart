import 'agent_tool_contract.dart';
import 'agent_tool_registry.dart';

/// Validates a complete batch before execution. The runner executes up to
/// eight calls serially in provider order, pausing for host approvals as needed.
/// Skill loading stays standalone so its instructions inform the next plan.
class AgentToolBatch {
  AgentToolBatch._();

  static const maxCalls = 8;

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
    if (calls.length > maxCalls) {
      return 'At most $maxCalls tool calls are allowed per response. Split the batch.';
    }
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
    if (calls.length > 1 && calls.any((call) => call.name == 'use_skill')) {
      return 'use_skill must be issued alone. Load the skill and wait for its '
          'result before proposing other tools.';
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
