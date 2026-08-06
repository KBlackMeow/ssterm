part of 'llm_service.dart';

// ───────────────────────────────────────────────────────────────────────────
// Provider-specific HTTP and streaming implementations.
//
// Extracted from `llm_service.dart` to keep that file under the project-wide
// 1000-line cap.  They are top-level private functions (instead of statics
// on [LlmService]) because Dart classes can't be split across files and
// these helpers have no instance state — they only differ by HTTP wire
// shape (OpenAI-compatible vs Anthropic vs Google Gemini).
// ───────────────────────────────────────────────────────────────────────────

// ── OpenAI-compatible (OpenAI, DeepSeek, etc.) ──────────────────────────

Future<LlmResponse> _callOpenAiCompatible(
  ProviderConfig provider,
  String model,
  String apiKey,
  List<AgentConversationItem> messages,
  String systemPrompt, {
  List<AgentToolDefinition> tools = const [],
}) async {
  final baseUrl = provider.baseUrl ?? 'https://api.openai.com/v1';
  final url = baseUrl.endsWith('/chat/completions')
      ? baseUrl
      : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

  final body = {
    'model': model,
    'messages': [
      {'role': 'system', 'content': systemPrompt},
      ...AgentProviderTools.openAiMessages(messages),
    ],
    'max_tokens': 4096,
    if (tools.isNotEmpty) 'tools': AgentProviderTools.openAiTools(tools),
    if (tools.isNotEmpty) 'tool_choice': 'auto',
    if (tools.isNotEmpty) 'parallel_tool_calls': false,
  };

  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.headers.set('Authorization', 'Bearer $apiKey');
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      return LlmResponse(
        text: '',
        error: 'HTTP ${response.statusCode}: ${_extractError(responseBody)}',
      );
    }

    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    final choice =
        (data['choices'] as List?)?.firstOrNull as Map<String, dynamic>?;
    final text = choice?['message']?['content'] as String? ?? '';
    return LlmResponse(
      text: text,
      toolCalls: AgentProviderTools.parseOpenAiToolCalls(data),
    );
  } finally {
    client.close(force: true);
  }
}

// ── Anthropic Claude ───────────────────────────────────────────────────

/// Wrap our system prompt in Anthropic's content-block list form with a
/// single `cache_control: {type: ephemeral}` breakpoint at the end.
///
/// Why this matters: the system prompt is ~3–4 KB (≈ 1 K tokens), it's
/// stable across a session, and EVERY agent loop iteration replays it.
/// With the breakpoint, Anthropic caches the prefix for 5 minutes and
/// subsequent calls within that window get a ~90% price discount on
/// the cached input tokens AND lower TTFT.  Without it, no caching.
///
/// Notes / constraints from
/// https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching:
///   • Minimum cacheable prefix: 1024 tokens (Sonnet/Opus).  Our prompt
///     is borderline — caches if the active model supports it, falls
///     through silently when below threshold.  Either way, no error.
///   • Cache key includes model, system, tools, and any earlier cached
///     prefix.  Toggling a skill DOES change the key (different prompt)
///     — that's fine; we just pay one cache-write the next turn.
///   • At most 4 breakpoints per request.  We use 1.  Future work could
///     add a second on the long-form skill body once it's loaded — that
///     would cache the skill across follow-up turns within the session.
///   • Anthropic ignores `cache_control` on requests below the size
///     threshold; safe to always include.
List<Map<String, dynamic>> _anthropicSystemBlock(String prompt) => [
  {
    'type': 'text',
    'text': prompt,
    'cache_control': {'type': 'ephemeral'},
  },
];

Future<LlmResponse> _callAnthropic(
  ProviderConfig provider,
  String model,
  String apiKey,
  List<AgentConversationItem> messages,
  String systemPrompt, {
  List<AgentToolDefinition> tools = const [],
}) async {
  final baseUrl = provider.baseUrl ?? 'https://api.anthropic.com';
  final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/messages';

  final apiMessages = AgentProviderTools.anthropicMessages(messages);

  final body = {
    'model': model,
    'system': _anthropicSystemBlock(systemPrompt),
    'messages': apiMessages,
    'max_tokens': 4096,
    if (tools.isNotEmpty) 'tools': AgentProviderTools.anthropicTools(tools),
    if (tools.isNotEmpty)
      'tool_choice': {'type': 'auto', 'disable_parallel_tool_use': true},
  };

  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.headers.set('x-api-key', apiKey);
    request.headers.set('anthropic-version', '2023-06-01');
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      return LlmResponse(
        text: '',
        error: 'HTTP ${response.statusCode}: ${_extractError(responseBody)}',
      );
    }

    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    final content = data['content'] as List?;
    if (content == null || content.isEmpty) {
      return LlmResponse(text: '');
    }
    final text = content
        .where((c) => c['type'] == 'text')
        .map((c) => c['text'] as String)
        .join('\n');
    return LlmResponse(
      text: text,
      toolCalls: AgentProviderTools.parseAnthropicToolCalls(data),
    );
  } finally {
    client.close(force: true);
  }
}

// ── Google Gemini ──────────────────────────────────────────────────────

Future<LlmResponse> _callGemini(
  ProviderConfig provider,
  String model,
  String apiKey,
  List<AgentConversationItem> messages,
  String systemPrompt, {
  List<AgentToolDefinition> tools = const [],
}) async {
  final baseUrl =
      provider.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta';
  final url =
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models/$model:generateContent?key=$apiKey';

  final contents = AgentProviderTools.geminiContents(messages);

  final body = {
    'system_instruction': {
      'parts': [
        {'text': systemPrompt},
      ],
    },
    'contents': contents,
    'generationConfig': {'maxOutputTokens': 4096},
    if (tools.isNotEmpty) 'tools': AgentProviderTools.geminiTools(tools),
  };

  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      return LlmResponse(
        text: '',
        error: 'HTTP ${response.statusCode}: ${_extractError(responseBody)}',
      );
    }

    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    final parts = candidates?.firstOrNull?['content']?['parts'] as List?;
    final text =
        parts
            ?.where((p) => p['text'] != null)
            .map((p) => p['text'] as String)
            .join('\n') ??
        '';
    return LlmResponse(
      text: text,
      toolCalls: AgentProviderTools.parseGeminiToolCalls(data),
    );
  } finally {
    client.close(force: true);
  }
}

// ── Shared utilities ───────────────────────────────────────────────────

String _extractError(String responseBody) {
  try {
    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    return data['error']?['message'] as String? ??
        data['error']?.toString() ??
        responseBody;
  } catch (_) {
    return responseBody.length > 200
        ? responseBody.substring(0, 200)
        : responseBody;
  }
}

/// Removes shell-prompt-looking prefixes that LLMs often emit at the
/// start of code-block lines (`$ ls -la`, `# apt update`, `> cd /foo`).
/// Keep `$` followed by a non-space character (variable expansions like
/// `$HOME`, `$()` substitutions) intact.
String _stripPseudoPrompts(String body) {
  final out = StringBuffer();
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    final m = RegExp(r'^(\s*)([\$#>])\s(.+)$').firstMatch(line);
    if (m != null) {
      line = '${m.group(1)}${m.group(3)}';
    }
    out.write(line);
    if (i < lines.length - 1) out.write('\n');
  }
  return out.toString();
}

// ── Streaming providers ────────────────────────────────────────────────
//
// Each stream yields LlmStreamEvent('reasoning' | 'text', chunk).
// The HttpClient instance is owned by [LlmService.chatStream] so callers
// can cancel an in-flight stream by closing the client (which aborts the
// underlying request).  Hence these functions take the client as an
// argument and never close it themselves.

// ── OpenAI / DeepSeek streaming ──────────────────────────────────────

class _OpenAiStreamingToolCall {
  String? id;
  String? name;
  final arguments = StringBuffer();
}

/// Stateful decoder for the `data:` payloads in an OpenAI-compatible SSE
/// stream. Public so its provider-wire behavior can be regression-tested
/// without making real network or keychain calls.
class OpenAiStreamAccumulator {
  final Map<int, _OpenAiStreamingToolCall> _toolCalls = {};

  String? finishReason;
  int malformedEventCount = 0;
  int? reasoningTokenCount;

  List<LlmStreamEvent> addData(String data) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) {
        malformedEventCount++;
        return const [];
      }
      final usage = decoded['usage'];
      if (usage is Map) {
        final details = usage['completion_tokens_details'];
        if (details is Map) {
          final tokens = details['reasoning_tokens'];
          if (tokens is int && tokens >= 0) reasoningTokenCount = tokens;
        }
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return const [];
      final rawChoice = choices.first;
      if (rawChoice is! Map) {
        malformedEventCount++;
        return const [];
      }
      final choice = rawChoice.cast<String, dynamic>();
      final rawFinishReason = choice['finish_reason'];
      if (rawFinishReason is String && rawFinishReason.isNotEmpty) {
        finishReason = rawFinishReason;
      }

      final rawDelta = choice['delta'];
      if (rawDelta == null) return const [];
      if (rawDelta is! Map) {
        malformedEventCount++;
        return const [];
      }
      final delta = rawDelta.cast<String, dynamic>();
      final rawToolCalls = delta['tool_calls'];
      if (rawToolCalls is List) {
        for (final raw in rawToolCalls) {
          if (raw is! Map) {
            malformedEventCount++;
            continue;
          }
          final index = raw['index'];
          if (index is! int) {
            malformedEventCount++;
            continue;
          }
          final pending = _toolCalls.putIfAbsent(
            index,
            _OpenAiStreamingToolCall.new,
          );
          final id = raw['id'];
          if (id is String && id.isNotEmpty) pending.id = id;
          final function = raw['function'];
          if (function is Map) {
            final name = function['name'];
            if (name is String && name.isNotEmpty) pending.name = name;
            final fragment = function['arguments'];
            if (fragment is String) pending.arguments.write(fragment);
          }
        }
      }

      final events = <LlmStreamEvent>[];
      final reasoning = delta['reasoning_content'];
      if (reasoning is String && reasoning.isNotEmpty) {
        events.add(LlmStreamEvent('reasoning', reasoning));
      }
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        events.add(LlmStreamEvent('text', content));
      }
      return events;
    } on FormatException {
      malformedEventCount++;
      return const [];
    } on TypeError {
      malformedEventCount++;
      return const [];
    }
  }

  List<LlmStreamEvent> finish() {
    final events = <LlmStreamEvent>[];
    for (final entry in _toolCalls.entries) {
      final pending = entry.value;
      final call = AgentToolCall.fromRaw(
        id: pending.id ?? 'call_openai_stream_${entry.key}',
        name: pending.name ?? '',
        arguments: pending.arguments.toString(),
      );
      if (call == null) {
        malformedEventCount++;
      } else {
        events.add(LlmStreamEvent('tool_call', '', toolCall: call));
      }
    }
    return events;
  }
}

Stream<LlmStreamEvent> _streamOpenAi(
  ProviderConfig provider,
  String model,
  String apiKey,
  List<AgentConversationItem> messages,
  HttpClient client,
  String systemPrompt, {
  List<AgentToolDefinition> tools = const [],
}) async* {
  final baseUrl = provider.baseUrl ?? 'https://api.openai.com/v1';
  final url = baseUrl.endsWith('/chat/completions')
      ? baseUrl
      : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

  final isDeepSeek = provider.id == 'deepseek';
  final body = <String, dynamic>{
    'model': model,
    'messages': [
      {'role': 'system', 'content': systemPrompt},
      ...AgentProviderTools.openAiMessages(messages),
    ],
    'max_tokens': 4096,
    'stream': true,
    if (tools.isNotEmpty) 'tools': AgentProviderTools.openAiTools(tools),
    if (tools.isNotEmpty) 'tool_choice': 'auto',
    if (tools.isNotEmpty) 'parallel_tool_calls': false,
    // DeepSeek-only: only `reasoning_effort` is recognised by their
    // OpenAI-compatible chat-completions endpoint.  The previous build
    // also sent `'thinking': {'type': 'enabled'}` — that's Anthropic's
    // shape and gets silently ignored (best case) or 400-rejected
    // (worst case) by DeepSeek.  Remove to keep the payload clean.
    if (isDeepSeek) 'reasoning_effort': 'high',
  };

  final request = await client.postUrl(Uri.parse(url));
  request.headers.set('Content-Type', 'application/json; charset=utf-8');
  request.headers.set('Authorization', 'Bearer $apiKey');
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();

  if (response.statusCode != 200) {
    final errorBody = await response.transform(utf8.decoder).join();
    throw Exception('HTTP ${response.statusCode}: ${_extractError(errorBody)}');
  }

  final accumulator = OpenAiStreamAccumulator();
  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('data: ')) continue;
    final data = line.substring(6).trim();
    if (data == '[DONE]') break;
    if (data.isEmpty) continue;
    for (final event in accumulator.addData(data)) {
      yield event;
    }
  }
  for (final event in accumulator.finish()) {
    yield event;
  }
  yield LlmStreamEvent.diagnostics(
    finishReason: accumulator.finishReason,
    malformedEventCount: accumulator.malformedEventCount,
    reasoningTokenCount: accumulator.reasoningTokenCount,
  );
}

// ── Anthropic streaming ──────────────────────────────────────────────

Stream<LlmStreamEvent> _streamAnthropic(
  ProviderConfig provider,
  String model,
  String apiKey,
  List<AgentConversationItem> messages,
  HttpClient client,
  String systemPrompt, {
  List<AgentToolDefinition> tools = const [],
}) async* {
  final baseUrl = provider.baseUrl ?? 'https://api.anthropic.com';
  final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/messages';

  final apiMessages = AgentProviderTools.anthropicMessages(messages);

  final body = <String, dynamic>{
    'model': model,
    'system': _anthropicSystemBlock(systemPrompt),
    'messages': apiMessages,
    'max_tokens': 4096,
    'stream': true,
    if (tools.isNotEmpty) 'tools': AgentProviderTools.anthropicTools(tools),
    if (tools.isNotEmpty)
      'tool_choice': {'type': 'auto', 'disable_parallel_tool_use': true},
  };
  // Extended thinking is only supported on Claude Sonnet 3.7+ and the v4+
  // Sonnet / Opus families.  Sending it to claude-3-5-sonnet, claude-3-haiku,
  // or claude-3-opus elicits a 400 "thinking is not supported for this
  // model" — gate the parameter behind a model-name match so the user can
  // freely switch models without hitting that wall.
  if (_anthropicSupportsThinking(model)) {
    body['thinking'] = {'type': 'enabled', 'budget_tokens': 2048};
  }

  final request = await client.postUrl(Uri.parse(url));
  request.headers.set('Content-Type', 'application/json; charset=utf-8');
  request.headers.set('x-api-key', apiKey);
  request.headers.set('anthropic-version', '2023-06-01');
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();

  if (response.statusCode != 200) {
    final errorBody = await response.transform(utf8.decoder).join();
    throw Exception('HTTP ${response.statusCode}: ${_extractError(errorBody)}');
  }

  final toolNames = <String, String>{};
  final toolArguments = <String, StringBuffer>{};
  String? currentToolId;
  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('data: ')) continue;
    final data = line.substring(6).trim();
    if (data.isEmpty) continue;
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      if (json['type'] == 'content_block_start') {
        final block = json['content_block'] as Map<String, dynamic>?;
        if (block?['type'] == 'tool_use') {
          final id = block?['id'] as String?;
          final name = block?['name'] as String?;
          if (id != null && name != null) {
            toolNames[id] = name;
            toolArguments[id] = StringBuffer();
            currentToolId = id;
          }
        }
      } else if (json['type'] == 'content_block_delta') {
        final delta = json['delta'] as Map<String, dynamic>?;
        if (delta == null) continue;
        if (delta['type'] == 'input_json_delta') {
          final partial = delta['partial_json'] as String?;
          if (partial != null && currentToolId != null) {
            toolArguments[currentToolId]!.write(partial);
          }
        } else if (delta['type'] == 'thinking_delta') {
          final text = delta['thinking'] as String?;
          if (text != null && text.isNotEmpty) {
            yield LlmStreamEvent('reasoning', text);
          }
        } else {
          final text = delta['text'] as String?;
          if (text != null && text.isNotEmpty) {
            yield LlmStreamEvent('text', text);
          }
        }
      }
    } catch (_) {}
  }
  for (final entry in toolArguments.entries) {
    final call = AgentToolCall.fromRaw(
      id: entry.key,
      name: toolNames[entry.key] ?? '',
      arguments: entry.value.toString(),
    );
    if (call != null) {
      yield LlmStreamEvent('tool_call', '', toolCall: call);
    }
  }
}

// ── Gemini streaming ─────────────────────────────────────────────────

Stream<LlmStreamEvent> _streamGemini(
  ProviderConfig provider,
  String model,
  String apiKey,
  List<AgentConversationItem> messages,
  HttpClient client,
  String systemPrompt, {
  List<AgentToolDefinition> tools = const [],
}) async* {
  final baseUrl =
      provider.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta';
  // `alt=sse` is REQUIRED: without it `:streamGenerateContent` returns a single
  // JSON array (not Server-Sent Events), so the `data: ` prefix parsing below
  // silently yields nothing and the user sees an eternal spinner.
  final url =
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models/$model:streamGenerateContent?alt=sse&key=$apiKey';

  final contents = AgentProviderTools.geminiContents(messages);

  final body = {
    'system_instruction': {
      'parts': [
        {'text': systemPrompt},
      ],
    },
    'contents': contents,
    'generationConfig': {'maxOutputTokens': 4096},
    if (tools.isNotEmpty) 'tools': AgentProviderTools.geminiTools(tools),
  };

  final request = await client.postUrl(Uri.parse(url));
  request.headers.set('Content-Type', 'application/json; charset=utf-8');
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();

  if (response.statusCode != 200) {
    final errorBody = await response.transform(utf8.decoder).join();
    throw Exception('HTTP ${response.statusCode}: ${_extractError(errorBody)}');
  }

  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('data: ')) continue;
    final data = line.substring(6).trim();
    if (data.isEmpty) continue;
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final usage = json['usageMetadata'];
      if (usage is Map) {
        final thoughtsTokenCount = usage['thoughtsTokenCount'];
        if (thoughtsTokenCount is int && thoughtsTokenCount >= 0) {
          yield LlmStreamEvent.diagnostics(
            malformedEventCount: 0,
            reasoningTokenCount: thoughtsTokenCount,
          );
        }
      }
      final candidates = json['candidates'] as List?;
      // Gemini interleaves `usageMetadata`/`promptFeedback` chunks that
      // have no `candidates` at all.  `break` would terminate the WHOLE
      // stream early and lose every following content chunk — so just
      // skip these housekeeping records and keep reading.
      if (candidates == null || candidates.isEmpty) continue;
      final parts = candidates.firstOrNull?['content']?['parts'] as List?;
      if (parts == null) continue;
      for (final part in parts) {
        final function = part['functionCall'];
        if (function is Map) {
          final call = AgentToolCall.fromRaw(
            id: 'call_gemini_stream',
            name: function['name'] as String? ?? '',
            arguments: function['args'],
          );
          if (call != null) {
            yield LlmStreamEvent('tool_call', '', toolCall: call);
          }
        }
        final text = part['text'] as String?;
        if (text != null && text.isNotEmpty) yield LlmStreamEvent('text', text);
      }
    } catch (_) {}
  }
}

// Whitelist of Anthropic model name patterns that support the
// `thinking` parameter (extended thinking).  As of 2026 this covers:
//   • claude-sonnet-4-*  /  claude-opus-4-*  (and any 5+)
//   • claude-3-7-sonnet-* (Sonnet 3.7 introduced extended thinking)
// Older 3.x families (3-5-sonnet, 3-haiku, 3-opus) do NOT support it
// and will return 400 if `thinking` is set.  Loose matching on dashes
// keeps the regex robust to date-suffixed model IDs like
// `claude-sonnet-4-5-20250115`.
bool _anthropicSupportsThinking(String model) {
  final m = model.toLowerCase();
  if (RegExp(r'claude-3-7-sonnet').hasMatch(m)) return true;
  if (RegExp(r'claude-(sonnet|opus)-[4-9]\b').hasMatch(m)) return true;
  return false;
}

// ── Ollama (local) ───────────────────────────────────────────────────
//
// We deliberately target the NATIVE `/api/chat` NDJSON endpoint (not
// the OpenAI-compatible `/v1/chat/completions` shim) for two reasons:
//
//   1. First-class `thinking` channel.  Reasoning models served by
//      Ollama (deepseek-r1, qwq, …) emit a separate `message.thinking`
//      field in the NDJSON deltas.  The OpenAI-compat shim folds that
//      into the visible reply, so we'd lose the reasoning/text split
//      that powers the collapsible "thinking" UI.
//
//   2. No fake auth.  Ollama has no auth by default; the OpenAI shim
//      politely ignores a missing `Authorization` header but our
//      shared `_streamOpenAi` always sets `Bearer <apiKey>` and would
//      need a placeholder.  Going native lets `requiresApiKey: false`
//      stay honest end-to-end.
//
// Wire shape per https://github.com/ollama/ollama/blob/main/docs/api.md:
//   POST $baseUrl/api/chat
//   body: {model, messages: [{role, content}], stream: true, options:{...}}
//   response: one JSON object per line, content in `message.content`,
//     reasoning in `message.thinking`, final object has `done: true`.
//
// `parseJsonStream: false` (default) is what makes streaming work — when
// it's true the daemon buffers the WHOLE answer and emits one object.

Future<LlmResponse> _callOllama(
  ProviderConfig provider,
  String model,
  List<AgentConversationItem> messages,
  String systemPrompt,
) async {
  final baseUrl = provider.baseUrl ?? 'http://localhost:11434';
  final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/chat';

  // System prompt rides at the head of the messages list — same
  // convention as OpenAI's chat format and what the Modelfile expects.
  final apiMessages = <Map<String, dynamic>>[
    {'role': 'system', 'content': systemPrompt},
    ...AgentProviderTools.legacyMessages(messages),
  ];

  final body = {'model': model, 'messages': apiMessages, 'stream': false};

  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      return LlmResponse(
        text: '',
        error: 'HTTP ${response.statusCode}: ${_extractError(responseBody)}',
      );
    }

    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    final message = data['message'] as Map<String, dynamic>?;
    final text = message?['content'] as String? ?? '';
    return LlmResponse(text: text);
  } finally {
    client.close(force: true);
  }
}

Stream<LlmStreamEvent> _streamOllama(
  ProviderConfig provider,
  String model,
  List<AgentConversationItem> messages,
  HttpClient client,
  String systemPrompt,
) async* {
  final baseUrl = provider.baseUrl ?? 'http://localhost:11434';
  final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/chat';

  final apiMessages = <Map<String, dynamic>>[
    {'role': 'system', 'content': systemPrompt},
    ...AgentProviderTools.legacyMessages(messages),
  ];

  final body = {'model': model, 'messages': apiMessages, 'stream': true};

  final request = await client.postUrl(Uri.parse(url));
  request.headers.set('Content-Type', 'application/json; charset=utf-8');
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();

  if (response.statusCode != 200) {
    final errorBody = await response.transform(utf8.decoder).join();
    throw Exception('HTTP ${response.statusCode}: ${_extractError(errorBody)}');
  }

  // NDJSON: one JSON object per line, no `data:` prefix, no `[DONE]`
  // sentinel.  The terminating object carries `done: true` (we don't
  // need to look at it — the stream just ends).  `LineSplitter` is
  // safe here because Ollama emits a literal `\n` between objects.
  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    try {
      final json = jsonDecode(trimmed) as Map<String, dynamic>;
      final message = json['message'] as Map<String, dynamic>?;
      if (message == null) continue;
      // Reasoning-model thinking channel: only present on r1/qwq/etc.
      // Yield BEFORE text so the order matches the wire order (Ollama
      // sometimes packs both into the same delta on completion).
      final thinking = message['thinking'] as String?;
      if (thinking != null && thinking.isNotEmpty) {
        yield LlmStreamEvent('reasoning', thinking);
      }
      final content = message['content'] as String?;
      if (content != null && content.isNotEmpty) {
        yield LlmStreamEvent('text', content);
      }
    } catch (_) {
      // Skip malformed lines — Ollama is well-behaved but a network
      // hiccup could chunk a line in half; the next valid object
      // resumes the stream.
    }
  }
}
