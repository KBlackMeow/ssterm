import 'dart:convert';
import 'dart:io';

import '../models/agent_config.dart';
import 'api_key_storage.dart';

/// Response from an LLM call.
class LlmResponse {
  final String text;
  final String? error;

  LlmResponse({required this.text, this.error});
}

/// A chunk yielded during streaming. [kind] is 'text' or 'reasoning'.
class LlmStreamEvent {
  final String kind;
  final String content;
  LlmStreamEvent(this.kind, this.content);
}

/// Minimal LLM service that routes requests to the configured provider.
/// Supports OpenAI-compatible APIs, Anthropic's native format, and
/// Google Gemini's native format.
class LlmService {
  // ── Marker matchers ─────────────────────────────────────────────────────
  //
  // The agent loop watches for two control markers in the model's reply:
  //   [TASK_COMPLETE] — stop the auto-loop, the task is done.
  //   [ASK_USER]      — pause the loop, wait for human input.
  //
  // We accept slightly loose forms because models sometimes wrap them in
  // markdown emphasis (`**[TASK_COMPLETE]**`), use a space instead of
  // underscore (`[TASK COMPLETE]`), or vary the case (`[Task_complete]`).
  // Without the loose form the marker leaks into the chat bubble (visible
  // to the user) AND the loop fails to detect completion.
  static final RegExp _taskCompleteRe = RegExp(
    r'\[\s*TASK[_ ]?COMPLETE\s*\]',
    caseSensitive: false,
  );
  static final RegExp _askUserRe = RegExp(
    r'\[\s*ASK[_ ]?USER\s*\]',
    caseSensitive: false,
  );
  // Strip variant: also eats surrounding markdown emphasis (`*`, `**`)
  // so we don't leave dangling asterisks in the rendered bubble.
  static final RegExp _taskCompleteStripRe = RegExp(
    r'\*{0,2}\[\s*TASK[_ ]?COMPLETE\s*\]\*{0,2}',
    caseSensitive: false,
  );
  static final RegExp _askUserStripRe = RegExp(
    r'\*{0,2}\[\s*ASK[_ ]?USER\s*\]\*{0,2}',
    caseSensitive: false,
  );
  static final RegExp _collapseBlankLinesRe = RegExp(r'\n{3,}');

  /// True if the model's reply contains the "task complete" sentinel in
  /// any of the accepted forms.
  static bool hasTaskCompleteMarker(String text) =>
      _taskCompleteRe.hasMatch(text);

  /// True if the model's reply asks the user to step in.
  static bool hasAskUserMarker(String text) => _askUserRe.hasMatch(text);

  /// Remove every TASK_COMPLETE / ASK_USER marker (and any markdown
  /// emphasis wrapped around it) from [text], then collapse the
  /// inevitable runs of blank lines so the chat bubble looks clean.
  static String stripCompletionMarkers(String text) {
    var out = text
        .replaceAll(_taskCompleteStripRe, '')
        .replaceAll(_askUserStripRe, '');
    out = out.replaceAll(_collapseBlankLinesRe, '\n\n');
    return out.trim();
  }

  // Possible marker forms we hide while streaming — the model's chunks
  // arrive a few characters at a time, so without this the user sees the
  // marker materialise (`[`, `[TA`, `[TASK_COM`, …) before the closing `]`
  // arrives and the full strip kicks in.  Includes the markdown-emphasis
  // variants so `**[TASK_COMPLETE]**` is hidden from its first asterisk.
  static const List<String> _streamingMarkerPrefixes = [
    '[TASK_COMPLETE]',
    '[TASK COMPLETE]',
    '[ASK_USER]',
    '[ASK USER]',
    '*[TASK_COMPLETE]*',
    '*[TASK COMPLETE]*',
    '*[ASK_USER]*',
    '*[ASK USER]*',
    '**[TASK_COMPLETE]**',
    '**[TASK COMPLETE]**',
    '**[ASK_USER]**',
    '**[ASK USER]**',
  ];

  // Match the unfinished-marker tail.  We allow a generous `[^\]\n]{0,30}`
  // body so a partially-streamed marker like `[TASK_COMP` is detected even
  // before the closing `]` arrives.  Anchored to end-of-string so we never
  // hide a `[bracket]` earlier in the message that the model already closed.
  static final RegExp _trailingPartialMarkerRe =
      RegExp(r'\*{0,2}\[[^\]\n]{0,30}$');

  /// Streaming-safe variant of [stripCompletionMarkers].
  ///
  /// During SSE streaming we receive `fullText` one chunk at a time, so the
  /// marker materialises gradually (`[`, `[T`, `[TASK`, …).  If we feed the
  /// raw text into the chat bubble the user briefly sees those fragments
  /// flicker on screen before the closing `]` lets [stripCompletionMarkers]
  /// erase them.
  ///
  /// This helper:
  ///   1. Strips every COMPLETE marker (same as [stripCompletionMarkers]).
  ///   2. Hides a trailing UNCLOSED `[...$` IFF it could be the start of one
  ///      of the markers we recognise.  False positives are bounded — a
  ///      markdown link like `[See here]` contains a `]` so it's not hidden;
  ///      worst case is a markdown link whose first letters happen to match
  ///      `[T` / `[A` / `[*[` is briefly invisible until its `]` arrives,
  ///      which is acceptable jitter for one frame.
  ///
  /// Unlike [stripCompletionMarkers], we do NOT collapse blank lines or
  /// trim trailing whitespace — those would cause distracting layout shifts
  /// as new tokens arrive.  The full normalisation runs once after the
  /// stream completes.
  static String stripStreamingMarkers(String text) {
    var out = text
        .replaceAll(_taskCompleteStripRe, '')
        .replaceAll(_askUserStripRe, '');
    final m = _trailingPartialMarkerRe.firstMatch(out);
    if (m != null) {
      final tail = m.group(0)!.toUpperCase();
      for (final candidate in _streamingMarkerPrefixes) {
        if (candidate.startsWith(tail)) {
          out = out.substring(0, m.start);
          break;
        }
      }
    }
    return out;
  }

  // ── Host environment block ──────────────────────────────────────────────
  //
  // The model picks dramatically different commands depending on the host
  // OS (Linux vs macOS BSD coreutils, Windows, …) and the active shell
  // (`set -o pipefail` works in bash/zsh but not POSIX sh).  We sniff the
  // host once and append it to the system prompt so the model can tailor
  // its output without us having to re-tokenise on every call.
  static String? _cachedSystemPrompt;

  static String get _systemPrompt {
    return _cachedSystemPrompt ??= _buildSystemPrompt();
  }

  static String _buildSystemPrompt() {
    return '$_systemPromptBase\n\n${_buildHostBlock()}';
  }

  static String _buildHostBlock() {
    String os;
    String osVersion;
    String shell = '(unknown)';
    String locale;
    String arch = '(unknown)';
    try {
      os = Platform.operatingSystem;
      osVersion = Platform.operatingSystemVersion;
      shell = Platform.environment['SHELL'] ?? '(unknown)';
      locale = Platform.localeName;
      // On macOS / Linux uname-style env vars give a cheap arch hint.
      arch = Platform.environment['HOSTTYPE'] ??
          Platform.environment['PROCESSOR_ARCHITECTURE'] ??
          '(unknown)';
    } catch (_) {
      // dart:io may be unavailable on some platforms (e.g. web builds).
      // Fall back to a minimal block — better to send nothing useful than
      // to crash the agent.
      os = 'unknown';
      osVersion = 'unknown';
      locale = 'unknown';
    }
    // Host block lives at the END of the system prompt on purpose — Claude
    // (and most LLMs) gives extra weight to the LAST tokens before the
    // conversation, so the runtime environment context dominates over any
    // generic shell knowledge the model picked up during training.
    return '''
<host_environment>
The SSTerm UI is running on:
- OS:     $os ($osVersion)
- Shell:  $shell
- Arch:   $arch
- Locale: $locale

When the active tab is a LOCAL terminal, commands run on THIS host — pick the right tool family (macOS uses BSD `sed` / `awk` / `find`; Linux uses GNU coreutils; Windows may need PowerShell).

When the active tab is an SSH session, commands run on the REMOTE — if behaviour is OS-specific, run `uname -srm` (or `cat /etc/os-release`) FIRST to detect the remote platform, THEN issue the OS-appropriate command.
</host_environment>''';
  }

  // ── System prompt design notes ──────────────────────────────────────────
  //
  // Structured with Anthropic's recommended XML-tag delimiters
  // (https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/use-xml-tags).
  // Claude attends to XML-tagged sections far more reliably than markdown
  // headings; OpenAI / DeepSeek / Gemini handle them as plain text without
  // any degradation, so the same prompt works across all four providers.
  //
  // The most behaviour-critical section is <turn_protocol>.  Earlier
  // versions of the prompt let the model emit a ```bash block AND
  // [TASK_COMPLETE] in the same turn — but the agent loop checks the
  // marker BEFORE executing commands, so the marker won and the command
  // was silently dropped.  That wasted a full LLM round-trip and confused
  // users ("why didn't the command run?").  The new <turn_protocol> spells
  // out three mutually-exclusive turn shapes, with a worked example of
  // INVESTIGATE-then-ANSWER spread across two turns.
  //
  // Other Anthropic best-practice levers we apply:
  //   • Identity + task statement at the very TOP (primacy bias).
  //   • Critical "no-combine" warning placed at the END of <turn_protocol>
  //     (recency bias).
  //   • Two concrete few-shot examples — one happy path, one error-pivot —
  //     so the model has reference patterns instead of having to derive
  //     them from prose rules.
  //   • A markdown table for the safety-class catalogue.  Tables are
  //     denser than bullets and the model parses Allowed-vs-Blocked at
  //     a glance instead of re-reading each bullet's "NOTE:" sentence.
  static const _systemPromptBase = '''
<role>
You are SSTerm Agent, an AI that solves user tasks by driving a real shell on the user's computer. You think, then issue ONE shell command per turn, observe the structured feedback, and iterate until the task is done. You do not see the user's screen — only the [Command executed] feedback ssterm sends back.
</role>

<feedback_format>
After every command you emit, you receive a user-role message in this EXACT shape:

[Command executed]
\$ <the command you sent>
[exit_code=<integer or "unknown">]
[output]
<stdout/stderr — ANSI-stripped, possibly truncated>

Or, when the command produced nothing:

[Command executed]
\$ <cmd>
[exit_code=0]
[output: <empty>]

Truncation flags appear (when present) BEFORE [output]:
- [capture_truncated=true …]   The shell produced more bytes than ssterm's 256 KB capture cap kept; the head AND/OR tail may be missing. DO NOT reason about absent lines — re-run with `head -n N` / `tail -n N` / `grep` for a deterministic slice.
- [feedback_truncated=true …]  Capture was complete; the MIDDLE was elided to fit the context window. Head and tail are exact; only the middle is missing.

Notes:
- Output is captured via OSC 133 shell integration (same protocol as iTerm2, VS Code, Warp, Zed). It contains only the command's stdout/stderr — NEVER the prompt, the echoed command, or color codes.
- exit_code=0 → success. Non-zero → failure. "unknown" → shell integration unavailable.
- Total output is capped at ~8 KB; longer outputs surface `[feedback_truncated=true …]`.
</feedback_format>

<turn_protocol>
Every turn you write MUST be exactly ONE of these three shapes. NEVER combine.

  1. INVESTIGATE — gather information or make a change.
     Format: One short sentence of intent, then one ```bash code block with ONE command.
     End-of-turn marker: NONE.
     Then: STOP. Wait for the next [Command executed] feedback before continuing.

  2. ANSWER — task is done; deliver the final result to the user.
     Format: Prose explanation of what you found / did.
     End-of-turn marker: [TASK_COMPLETE] on its own line, last thing in the message.
     NO ```bash block on this turn.

  3. ASK — you need a decision, secret, or confirmation from the user before continuing.
     Format: One concrete question.
     End-of-turn marker: [ASK_USER] on its own line, last thing in the message.
     NO ```bash block on this turn.

CRITICAL — DO NOT MIX SHAPES:
An INVESTIGATE turn (with a ```bash block) MUST NOT also contain [TASK_COMPLETE] or [ASK_USER]. The agent loop checks the marker BEFORE executing your command — if both appear in the same turn, the marker wins, your command is silently dropped, and the round-trip is wasted. Always wait one full turn between issuing a command and declaring the task complete.

USE ASK BEFORE DESTRUCTIVE OR EXPENSIVE OPERATIONS — never INVESTIGATE — for: `rm -rf`, `DROP TABLE`, package upgrades, multi-GB downloads, anything system-wide. State the intent, then end with [ASK_USER]. Wait for the user to confirm before you actually run it.

<example name="iterate-then-conclude">
User: "What's my LAN IP address?"

Your turn 1 — INVESTIGATE:

I'll list non-loopback IPv4 addresses.

```bash
ifconfig | awk '/inet /{print \$2}' | grep -v 127.0.0.1
```

(ssterm replies on its turn with [Command executed], exit_code=0, output: 192.168.1.42)

Your turn 2 — ANSWER:

Your LAN IP is **192.168.1.42**.

[TASK_COMPLETE]
</example>

<example name="error-recovery">
User: "Show me the prime factors of 5040."

Your turn 1 — INVESTIGATE:

I'll factor 5040 with the `factor` utility.

```bash
factor 5040
```

(ssterm replies: exit_code=127, output: "factor: command not found")

Your turn 2 — INVESTIGATE (pivot, do NOT re-run the same command):

`factor` isn't installed; falling back to a Python one-liner.

```bash
python3 -c "n=5040; p=[]
while n>1:
  for i in range(2, n+1):
    if n%i==0: p.append(i); n//=i; break
print(p)"
```

(ssterm replies: exit_code=0, output: [2, 2, 2, 2, 3, 3, 5, 7])

Your turn 3 — ANSWER:

5040 = 2⁴ × 3² × 5 × 7.

[TASK_COMPLETE]
</example>
</turn_protocol>

<rules>
- Be concise. Short prose, small verifiable steps.
- ONE command per ```bash block. Chain with `&&` or `;` inside one block when atomic; never emit multiple blocks for one logical step.
- Always explain the command in ONE short sentence BEFORE its block.
- DO NOT emit the same command twice in one turn (ssterm dedupes exact duplicates anyway, but it noises the transcript and confuses the user).
- Use the captured exit_code and output to plan the next step. On non-zero exit, diagnose and PIVOT — never blindly re-run the same command.
- Prefer non-interactive flags (`-y`, `--no-pager`, `head -n`, `--batch`). Avoid commands that wait for stdin.
- If you don't know something, say so plainly. NEVER fabricate output, exit codes, or facts about the host.
</rules>

<safety_check>
ssterm pre-flights every command. If feedback contains `[ssterm safety check] …`, your command was REJECTED before reaching the shell — switch strategy on the next turn. Re-running the same command will be rejected again.

Blocked classes and their non-interactive equivalents:

| Class                | Blocked form                                                                                     | Use instead                                                                                                                                              |
|----------------------|--------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| Background `&`       | `cmd &`                                                                                          | `nohup cmd > /tmp/out.log 2>&1 & disown`, then read `/tmp/out.log` on a later turn                                                                       |
| Always-interactive   | `vim`, `vi`, `nvim`, `emacs`, `nano`, `less`, `more`, `man`, `info`, `top`, `htop`, `btop`, `tmux`, `screen`, `telnet`, `ftp`, `sftp` | `cat`/`grep`, `ps`/`pgrep`, `man -P cat <topic>`, `head`/`tail`                                                                                          |
| Bare REPL            | `python` / `python3` / `node` / `irb` / `ipython` / `lua` / `ghci` (or any of these with `-i`)    | `python3 -c "…"`, `python3 script.py`, `python3 -m mod`, `node -e "…"`, `node script.js` — all ALLOWED                                                   |
| Bare DB CLI          | `mysql`, `psql`, `redis-cli`, `mongo`, `mongosh`, `sqlite3` (with no execute flag)                | `mysql -e "SELECT 1"`, `psql -c "…"` / `psql -f f.sql`, `redis-cli ping`, `mongosh --eval "…"`, `sqlite3 db.sqlite "SELECT 1"` — all ALLOWED            |
| Indefinite-blocking  | `tail -f`, `watch …`                                                                             | `tail -n N <file>`, run the inner command once                                                                                                          |
</safety_check>
''';

  /// Send a chat message to the configured LLM and return the response.
  static Future<LlmResponse> chat({
    required AgentConfig config,
    required List<Map<String, String>> messages,
  }) async {
    final provider = config.current;
    if (provider == null) {
      return LlmResponse(text: '', error: 'No enabled provider selected.');
    }

    final model = config.resolvedModel;
    if (model == null) {
      return LlmResponse(text: '', error: 'No model available for the selected provider.');
    }

    final apiKey = await ApiKeyStorage.load(provider.id);
    if (apiKey == null || apiKey.isEmpty) {
      return LlmResponse(text: '', error: 'API key not configured for ${provider.displayName}.');
    }

    try {
      switch (provider.id) {
        case 'claude':
          return _callAnthropic(provider, model, apiKey, messages);
        case 'gemini':
          return _callGemini(provider, model, apiKey, messages);
        default:
          // OpenAI-compatible (OpenAI, DeepSeek, etc.)
          return _callOpenAiCompatible(provider, model, apiKey, messages);
      }
    } catch (e) {
      return LlmResponse(text: '', error: 'Request failed: $e');
    }
  }

  // ── OpenAI-compatible (OpenAI, DeepSeek, etc.) ──────────────────────────

  static Future<LlmResponse> _callOpenAiCompatible(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
  ) async {
    final baseUrl = provider.baseUrl ?? 'https://api.openai.com/v1';
    final url = baseUrl.endsWith('/chat/completions')
        ? baseUrl
        : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        ...messages.map((m) => {'role': m['role'], 'content': m['content']}),
      ],
      'max_tokens': 4096,
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
      final choice = (data['choices'] as List?)?.firstOrNull as Map<String, dynamic>?;
      final text = choice?['message']?['content'] as String? ?? '';
      return LlmResponse(text: text);
    } finally {
      client.close(force: true);
    }
  }

  // ── Anthropic Claude ───────────────────────────────────────────────────

  static Future<LlmResponse> _callAnthropic(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
  ) async {
    final baseUrl = provider.baseUrl ?? 'https://api.anthropic.com';
    final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/messages';

    // Map messages into Anthropic format: system + messages list.
    final apiMessages = messages.map((m) => {
      'role': m['role'],
      'content': m['content'],
    }).toList();

    final body = {
      'model': model,
      'system': _systemPrompt,
      'messages': apiMessages,
      'max_tokens': 4096,
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
      return LlmResponse(text: text);
    } finally {
      client.close(force: true);
    }
  }

  // ── Google Gemini ──────────────────────────────────────────────────────

  static Future<LlmResponse> _callGemini(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
  ) async {
    final baseUrl = provider.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta';
    final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models/$model:generateContent?key=$apiKey';

    // Build Gemini contents from messages.
    final contents = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'] == 'assistant' ? 'model' : 'user';
      contents.add({
        'role': role,
        'parts': [{'text': m['content']}],
      });
    }

    final body = {
      'system_instruction': {
        'parts': [{'text': _systemPrompt}],
      },
      'contents': contents,
      'generationConfig': {
        'maxOutputTokens': 4096,
      },
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
      final parts = candidates
          ?.firstOrNull?['content']?['parts'] as List?;
      final text = parts
          ?.where((p) => p['text'] != null)
          .map((p) => p['text'] as String)
          .join('\n') ?? '';
      return LlmResponse(text: text);
    } finally {
      client.close(force: true);
    }
  }

  static String _extractError(String responseBody) {
    try {
      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      return data['error']?['message'] as String? ??
          data['error']?.toString() ??
          responseBody;
    } catch (_) {
      return responseBody.length > 200 ? responseBody.substring(0, 200) : responseBody;
    }
  }

  /// Parse shell commands from a markdown response.
  ///
  /// Only fenced blocks tagged `bash` / `sh` / `shell` / `zsh` (case
  /// insensitive) are recognised — UNTAGGED blocks are intentionally
  /// IGNORED, otherwise the agent would happily try to execute snippets
  /// the LLM intended as plain text (warnings, JSON examples, diff blocks).
  ///
  /// Each line of the body is also stripped of pseudo-prompt prefixes
  /// (`$ `, `# `, `> `) that GPT-4 / Claude routinely add — those would
  /// otherwise produce `command not found: $`.
  ///
  /// **EXACT duplicate commands are deduplicated, preserving first-seen
  /// order.**  Models occasionally emit the same command twice — once in
  /// an "explanation" code block and again in a "now let me run it" code
  /// block — and without this dedupe the auto-execute loop would run it
  /// twice.  The result is observable in the chat panel (the duplicate
  /// fence is still rendered by `gpt_markdown`), but the agent's exec
  /// path treats both as one command.
  static List<String> extractCommands(String text) {
    final seen = <String>{};
    final commands = <String>[];
    // Mandatory language tag — the trailing `?` of the previous version
    // matched untagged blocks too, which was a foot-gun.
    final regex = RegExp(
      r'```(?:bash|shell|sh|zsh)\s*\n([\s\S]*?)```',
      caseSensitive: false,
    );
    for (final match in regex.allMatches(text)) {
      final raw = match.group(1);
      if (raw == null) continue;
      final cleaned = _stripPseudoPrompts(raw).trim();
      if (cleaned.isEmpty) continue;
      if (seen.add(cleaned)) commands.add(cleaned);
    }
    return commands;
  }

  /// Removes shell-prompt-looking prefixes that LLMs often emit at the
  /// start of code-block lines (`$ ls -la`, `# apt update`, `> cd /foo`).
  /// Keep `$` followed by a non-space character (variable expansions like
  /// `$HOME`, `$()` substitutions) intact.
  static String _stripPseudoPrompts(String body) {
    final out = StringBuffer();
    final lines = body.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      // Match ONLY the indent + a single prompt char + a single space.
      // `$ cmd`  →  `cmd`
      // `# cmd`  →  `cmd` (root prompt)
      // `> cmd`  →  `cmd` (PS2 continuation)
      // `$HOME` →  unchanged (no space after $)
      final m = RegExp(r'^(\s*)([\$#>])\s(.+)$').firstMatch(line);
      if (m != null) {
        line = '${m.group(1)}${m.group(3)}';
      }
      out.write(line);
      if (i < lines.length - 1) out.write('\n');
    }
    return out.toString();
  }

  // ── Streaming ─────────────────────────────────────────────────────────

  /// Start a streaming chat and return the stream along with a cancel function.
  /// Yields [LlmStreamEvent] chunks. kind='reasoning' for thinking content,
  /// kind='text' for the final answer.
  static ({Stream<LlmStreamEvent> stream, void Function() cancel}) chatStream({
    required AgentConfig config,
    required List<Map<String, String>> messages,
  }) {
    final client = HttpClient();
    return (
      stream: _chatStreamInternal(config, messages, client),
      cancel: () => client.close(force: true),
    );
  }

  static Stream<LlmStreamEvent> _chatStreamInternal(
    AgentConfig config,
    List<Map<String, String>> messages,
    HttpClient client,
  ) async* {
    final provider = config.current;
    if (provider == null) throw Exception('No enabled provider selected.');

    final model = config.resolvedModel;
    if (model == null) throw Exception('No model available for the selected provider.');

    final apiKey = await ApiKeyStorage.load(provider.id);
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('API key not configured for ${provider.displayName}.');
    }

    switch (provider.id) {
      case 'claude':
        yield* _streamAnthropic(provider, model, apiKey, messages, client);
      case 'gemini':
        yield* _streamGemini(provider, model, apiKey, messages, client);
      default:
        yield* _streamOpenAi(provider, model, apiKey, messages, client);
    }
  }

  // ── OpenAI / DeepSeek streaming ──────────────────────────────────────

  static Stream<LlmStreamEvent> _streamOpenAi(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
    HttpClient client,
  ) async* {
    final baseUrl = provider.baseUrl ?? 'https://api.openai.com/v1';
    final url = baseUrl.endsWith('/chat/completions')
        ? baseUrl
        : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

    final isDeepSeek = provider.id == 'deepseek';
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        ...messages.map((m) => {'role': m['role'], 'content': m['content']}),
      ],
      'max_tokens': 4096,
      'stream': true,
      if (isDeepSeek) 'thinking': {'type': 'enabled'},
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

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data == '[DONE]') break;
      if (data.isEmpty) continue;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        final delta = choices?.firstOrNull?['delta'] as Map<String, dynamic>?;
        if (delta == null) continue;
        // reasoning_content (DeepSeek thinking mode)
        final reasoning = delta['reasoning_content'] as String?;
        if (reasoning != null && reasoning.isNotEmpty) {
          yield LlmStreamEvent('reasoning', reasoning);
        }
        // regular content
        final content = delta['content'] as String?;
        if (content != null && content.isNotEmpty) {
          yield LlmStreamEvent('text', content);
        }
      } catch (_) {}
    }
  }

  // ── Anthropic streaming ──────────────────────────────────────────────

  static Stream<LlmStreamEvent> _streamAnthropic(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
    HttpClient client,
  ) async* {
    final baseUrl = provider.baseUrl ?? 'https://api.anthropic.com';
    final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/messages';

    final apiMessages = messages.map((m) => {
      'role': m['role'],
      'content': m['content'],
    }).toList();

    final body = {
      'model': model,
      'system': _systemPrompt,
      'messages': apiMessages,
      'max_tokens': 4096,
      'stream': true,
      'thinking': {
        'type': 'enabled',
        'budget_tokens': 2048,
      },
    };

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

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data.isEmpty) continue;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        if (json['type'] == 'content_block_delta') {
          final delta = json['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;
          if (delta['type'] == 'thinking_delta') {
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
  }

  // ── Gemini streaming ─────────────────────────────────────────────────

  static Stream<LlmStreamEvent> _streamGemini(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
    HttpClient client,
  ) async* {
    final baseUrl = provider.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta';
    final url =
        '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models/$model:streamGenerateContent?key=$apiKey';

    final contents = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'] == 'assistant' ? 'model' : 'user';
      contents.add({
        'role': role,
        'parts': [{'text': m['content']}],
      });
    }

    final body = {
      'system_instruction': {
        'parts': [{'text': _systemPrompt}],
      },
      'contents': contents,
      'generationConfig': {
        'maxOutputTokens': 4096,
      },
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
        final candidates = json['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) break;
        final parts = candidates.firstOrNull?['content']?['parts'] as List?;
        if (parts == null) continue;
        for (final part in parts) {
          final text = part['text'] as String?;
          if (text != null && text.isNotEmpty) yield LlmStreamEvent('text', text);
        }
      } catch (_) {}
    }
  }
}
