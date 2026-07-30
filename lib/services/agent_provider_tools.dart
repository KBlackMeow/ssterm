import 'dart:convert';

import 'agent_tool_contract.dart';

/// Translates the shared tool contract to native provider shapes and parses
/// native responses back to [AgentToolCall].
class AgentProviderTools {
  AgentProviderTools._();

  static List<Map<String, Object?>> openAiTools(
    Iterable<AgentToolDefinition> definitions,
  ) => [
    for (final definition in definitions)
      {
        'type': 'function',
        'function': {
          'name': definition.name,
          'description': definition.description,
          'parameters': definition.toJsonSchema(),
          'strict': definition.strict,
        },
      },
  ];

  static List<Map<String, Object?>> anthropicTools(
    Iterable<AgentToolDefinition> definitions,
  ) => [
    for (final definition in definitions)
      {
        'name': definition.name,
        'description': definition.description,
        'input_schema': definition.toJsonSchema(),
      },
  ];

  static List<Map<String, Object?>> geminiTools(
    Iterable<AgentToolDefinition> definitions,
  ) => [
    {
      'functionDeclarations': [
        for (final definition in definitions)
          {
            'name': definition.name,
            'description': definition.description,
            'parameters': definition.toJsonSchema(),
          },
      ],
    },
  ];

  /// Serializes the shared transcript to OpenAI Chat Completions messages.
  static List<Map<String, Object?>> openAiMessages(
    Iterable<AgentConversationItem> transcript,
  ) => [
    for (final item in transcript)
      if (item.role != null)
        {'role': item.role!, 'content': item.content ?? ''}
      else if (item.toolCalls.isNotEmpty)
        {
          'role': 'assistant',
          'content': item.content,
          'tool_calls': [
            for (final call in item.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.providerName ?? call.name,
                  'arguments': jsonEncode(
                    call.providerArguments ?? call.arguments,
                  ),
                },
              },
          ],
        }
      else if (item.toolResults.isNotEmpty)
        for (final result in item.toolResults)
          {
            'role': 'tool',
            'tool_call_id': result.toolCallId,
            'content': result.content,
          },
  ];

  /// Serializes the shared transcript to Anthropic Messages content blocks.
  static List<Map<String, Object?>> anthropicMessages(
    Iterable<AgentConversationItem> transcript,
  ) => [
    for (final item in transcript)
      if (item.role != null)
        {'role': item.role!, 'content': item.content ?? ''}
      else if (item.toolCalls.isNotEmpty)
        {
          'role': 'assistant',
          'content': [
            if (item.content != null && item.content!.isNotEmpty)
              {'type': 'text', 'text': item.content},
            for (final call in item.toolCalls)
              {
                'type': 'tool_use',
                'id': call.id,
                'name': call.providerName ?? call.name,
                'input': call.providerArguments ?? call.arguments,
              },
          ],
        }
      else if (item.toolResults.isNotEmpty)
        {
          'role': 'user',
          'content': [
            for (final result in item.toolResults)
              {
                'type': 'tool_result',
                'tool_use_id': result.toolCallId,
                'content': result.content,
                if (result.isError) 'is_error': true,
              },
          ],
        },
  ];

  /// Serializes the shared transcript to Gemini `contents`.
  static List<Map<String, Object?>> geminiContents(
    Iterable<AgentConversationItem> transcript,
  ) {
    final namesByCallId = <String, String>{};
    final contents = <Map<String, Object?>>[];
    for (final item in transcript) {
      if (item.role != null) {
        contents.add({
          'role': item.role == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': item.content ?? ''},
          ],
        });
      } else if (item.toolCalls.isNotEmpty) {
        for (final call in item.toolCalls) {
          namesByCallId[call.id] = call.providerName ?? call.name;
        }
        contents.add({
          'role': 'model',
          'parts': [
            if (item.content != null && item.content!.isNotEmpty)
              {'text': item.content},
            for (final call in item.toolCalls)
              {
                'functionCall': {
                  'name': call.providerName ?? call.name,
                  'args': call.providerArguments ?? call.arguments,
                },
              },
          ],
        });
      } else if (item.toolResults.isNotEmpty) {
        contents.add({
          'role': 'user',
          'parts': [
            for (final result in item.toolResults)
              {
                'functionResponse': {
                  'name': namesByCallId[result.toolCallId] ?? 'unknown_tool',
                  'response': {
                    'tool_call_id': result.toolCallId,
                    'content': result.content,
                    if (result.isError) 'is_error': true,
                  },
                },
              },
          ],
        });
      }
    }
    return contents;
  }

  /// Text-only compatibility transcript for providers without native tools.
  static List<Map<String, String>> legacyMessages(
    Iterable<AgentConversationItem> transcript,
  ) => [
    for (final item in transcript)
      if (item.role != null)
        {'role': item.role!, 'content': item.content ?? ''}
      else if (item.toolCalls.isNotEmpty)
        {
          'role': 'assistant',
          'content': jsonEncode(<Object?>[
            if (item.content != null && item.content!.isNotEmpty) item.content,
            ...item.toolCalls.map((call) => call.toLegacyJson()),
          ]),
        }
      else if (item.toolResults.isNotEmpty)
        {
          'role': 'user',
          'content': item.toolResults
              .map((result) => result.content)
              .join('\n\n'),
        },
  ];

  static List<AgentToolCall> parseOpenAiToolCalls(
    Map<String, dynamic> response,
  ) {
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) return const [];
    final message = (choices.first as Map?)?['message'];
    final rawCalls = (message as Map?)?['tool_calls'];
    if (rawCalls is! List) return const [];
    final calls = <AgentToolCall>[];
    for (final raw in rawCalls) {
      if (raw is! Map) continue;
      final function = raw['function'];
      if (function is! Map) continue;
      final call = AgentToolCall.fromRaw(
        id: raw['id'] as String? ?? 'call_openai_${calls.length + 1}',
        name: function['name'] as String? ?? '',
        arguments: function['arguments'],
      );
      if (call != null) calls.add(call);
    }
    return calls;
  }

  static List<AgentToolCall> parseAnthropicToolCalls(
    Map<String, dynamic> response,
  ) {
    final content = response['content'];
    if (content is! List) return const [];
    final calls = <AgentToolCall>[];
    for (final raw in content) {
      if (raw is! Map || raw['type'] != 'tool_use') continue;
      final call = AgentToolCall.fromRaw(
        id: raw['id'] as String? ?? 'call_anthropic_${calls.length + 1}',
        name: raw['name'] as String? ?? '',
        arguments: raw['input'],
      );
      if (call != null) calls.add(call);
    }
    return calls;
  }

  static List<AgentToolCall> parseGeminiToolCalls(
    Map<String, dynamic> response,
  ) {
    final candidates = response['candidates'];
    if (candidates is! List) return const [];
    final calls = <AgentToolCall>[];
    for (final candidate in candidates) {
      final parts = (candidate as Map?)?['content']?['parts'];
      if (parts is! List) continue;
      for (final part in parts) {
        final function = (part as Map?)?['functionCall'];
        if (function is! Map) continue;
        final call = AgentToolCall.fromRaw(
          id: 'call_gemini_${calls.length + 1}',
          name: function['name'] as String? ?? '',
          arguments: function['args'],
        );
        if (call != null) calls.add(call);
      }
    }
    return calls;
  }
}
