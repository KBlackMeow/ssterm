import 'dart:convert';
import 'dart:io';

import '../models/agent_config.dart';
import 'api_key_storage.dart';
import 'skill_service.dart';

part 'llm_service_prompts.dart';
part 'llm_service_providers.dart';

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
  // [USE_SKILL: <id>] — emitted by the model to pull in a skill playbook.
  // The id charset is intentionally narrow (slug-safe) so we don't accidentally
  // match prose like `[USE_SKILL: the one we discussed yesterday]`.  Matches
  // `USE_SKILL`, `USE SKILL`, `USESKILL`; `:` and `=` are both accepted as the
  // separator since smaller models sometimes invent their own punctuation.
  static final RegExp _useSkillRe = RegExp(
    r'\[\s*USE[_ ]?SKILL\s*[:=]\s*([a-zA-Z0-9._-]+)\s*\]',
    caseSensitive: false,
  );
  // [WRITE_FILE_BEGIN: <path>] … [WRITE_FILE_END] — file-write tool.
  // Multiline marker pair: BEGIN line carries the absolute path,
  // everything between (verbatim, no shell interpretation) is the new
  // file's contents, END line on its own closes it.
  //
  // We use a marker PAIR instead of a single `[WRITE_FILE: path]` +
  // fenced code block because:
  //   • Code fences inside file content (e.g. writing a markdown file
  //     that itself contains ```bash blocks) would otherwise terminate
  //     the outer fence and leak the rest as agent prose.
  //   • The agent loop already runs `extractCommands` on every reply
  //     to harvest ```bash blocks — using a fence here would force a
  //     second parse pass to distinguish "execute me" from "write me".
  //
  // Capture groups:
  //   1: absolute path (raw — adapter validates)
  //   2: file body (verbatim, including a leading newline we strip)
  //
  // Dot-all so the body can span any number of lines; non-greedy so a
  // turn with two consecutive write blocks still matches each one
  // individually instead of swallowing the gap.
  //
  // Both markers MUST sit at the start of their own line (optional leading
  // whitespace allowed for indented bullet lists).  Without this anchoring
  // a model that DOCUMENTS the write tool — e.g. teaching the user how to
  // use it inline as `here's the marker: [WRITE_FILE_END]` — would
  // prematurely close a real subsequent write block AND a model that
  // dumps a write-block-inside-an-explanation paragraph could be
  // mistaken for a real write.  System prompt always emits the markers
  // on their own lines, so this is a tightening, not a behaviour change.
  static final RegExp _writeFileRe = RegExp(
    r'^[ \t]*\[\s*WRITE[_ ]?FILE[_ ]?BEGIN\s*[:=]\s*([^\]\n]+?)\s*\][ \t]*$'
    r'(.*?)'
    r'^[ \t]*\[\s*WRITE[_ ]?FILE[_ ]?END\s*\][ \t]*$',
    caseSensitive: false,
    multiLine: true,
    dotAll: true,
  );
  // [WEB_SEARCH: <query>] — Brave-backed web search tool.  Unlike USE_SKILL
  // the body is a free-form QUERY (so we MUST allow spaces, punctuation,
  // accented characters, quote marks, …).  Capture group keeps everything
  // between `:` and the LAST `]` on the line — the inner pattern is
  // intentionally non-greedy and rejects newlines, so a stray `]` in prose
  // earlier in the message cannot close the marker prematurely.
  //
  // Accepts `WEB_SEARCH`, `WEB SEARCH`, `WEBSEARCH`; same `:`/`=` separator
  // tolerance as USE_SKILL.  Case-insensitive.
  static final RegExp _webSearchRe = RegExp(
    r'\[\s*WEB[_ ]?SEARCH\s*[:=]\s*([^\]\n]+?)\s*\]',
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
  static final RegExp _useSkillStripRe = RegExp(
    r'\*{0,2}\[\s*USE[_ ]?SKILL\s*[:=]\s*[a-zA-Z0-9._-]+\s*\]\*{0,2}',
    caseSensitive: false,
  );
  static final RegExp _webSearchStripRe = RegExp(
    r'\*{0,2}\[\s*WEB[_ ]?SEARCH\s*[:=]\s*[^\]\n]+?\s*\]\*{0,2}',
    caseSensitive: false,
  );
  // Strip variant for WRITE_FILE — eats the whole BEGIN..END region
  // including the file body, so the rendered chat bubble doesn't show
  // a giant verbatim paste of the new file contents (the Apply card
  // surfaces that separately, with a diff preview).  Same line-anchoring
  // rationale as `_writeFileRe` above.
  static final RegExp _writeFileStripRe = RegExp(
    r'^[ \t]*\*{0,2}\[\s*WRITE[_ ]?FILE[_ ]?BEGIN\s*[:=]\s*[^\]\n]+?\s*\]\*{0,2}[ \t]*$'
    r'.*?'
    r'^[ \t]*\*{0,2}\[\s*WRITE[_ ]?FILE[_ ]?END\s*\]\*{0,2}[ \t]*$',
    caseSensitive: false,
    multiLine: true,
    dotAll: true,
  );
  static final RegExp _collapseBlankLinesRe = RegExp(r'\n{3,}');

  /// True if the model's reply contains the "task complete" sentinel in
  /// any of the accepted forms.
  static bool hasTaskCompleteMarker(String text) =>
      _taskCompleteRe.hasMatch(text);

  /// True if the model's reply asks the user to step in.
  static bool hasAskUserMarker(String text) => _askUserRe.hasMatch(text);

  /// Extract the skill id from a `[USE_SKILL: <id>]` marker, or null when
  /// the reply doesn't request a skill.  Lower-cased so callers can use
  /// the id as a stable key into [SkillService] regardless of how the
  /// model capitalised it.
  static String? extractUseSkillMarker(String text) {
    final m = _useSkillRe.firstMatch(text);
    return m?.group(1)?.toLowerCase();
  }

  /// Extract the query from a `[WEB_SEARCH: <query>]` marker, or null
  /// when the reply doesn't request a search.  Unlike the skill id, the
  /// query is returned VERBATIM (preserving case, punctuation, accents)
  /// because Brave is case-sensitive for some queries and lower-casing
  /// would silently change result ranking.
  static String? extractWebSearchQuery(String text) {
    final m = _webSearchRe.firstMatch(text);
    final q = m?.group(1)?.trim();
    return (q == null || q.isEmpty) ? null : q;
  }

  /// Extract the FIRST `[WRITE_FILE_BEGIN: <path>] … [WRITE_FILE_END]`
  /// block, or null when the reply doesn't propose a write.
  ///
  /// Returns `(path, content)`:
  ///   • path is trimmed but otherwise verbatim — the adapter
  ///     validates absoluteness, `~` expansion, scheme, etc.
  ///   • content is the body between the markers.  We strip ONE leading
  ///     newline (LLMs almost always emit `[WRITE_FILE_BEGIN: …]\n…`
  ///     and the leading `\n` is decorative, not part of the file) AND
  ///     one trailing newline (model tends to put the closing marker
  ///     on its own line, contributing a trailing `\n` that wasn't
  ///     part of the intended file).  Files that LEGITIMATELY end with
  ///     `\n` (POSIX text files, which is most of them) get it back
  ///     when the model includes a blank line before the END marker —
  ///     same convention as bash heredocs.
  ///
  /// We deliberately don't return ALL matches — multi-write proposals
  /// per turn are explicitly forbidden by the system prompt (one write
  /// per turn so the user can Apply/Reject individually).  If a future
  /// version of the prompt allows it, switch to `allMatches`.
  static ({String path, String content})? extractWriteFile(String text) {
    final m = _writeFileRe.firstMatch(text);
    if (m == null) return null;
    final path = m.group(1)?.trim();
    if (path == null || path.isEmpty) return null;
    var body = m.group(2) ?? '';
    if (body.startsWith('\r\n')) {
      body = body.substring(2);
    } else if (body.startsWith('\n')) {
      body = body.substring(1);
    }
    if (body.endsWith('\r\n')) {
      body = body.substring(0, body.length - 2);
    } else if (body.endsWith('\n')) {
      body = body.substring(0, body.length - 1);
    }
    return (path: path, content: body);
  }

  /// Remove every TASK_COMPLETE / ASK_USER / USE_SKILL / WEB_SEARCH /
  /// WRITE_FILE marker (and any markdown emphasis wrapped around
  /// them) from [text], then collapse the inevitable runs of blank
  /// lines so the chat bubble looks clean.
  ///
  /// WRITE_FILE is stripped INCLUDING its body — the chat-card UI
  /// surfaces the proposed file separately with a diff preview, so
  /// dumping the verbatim body into the rendered bubble too would
  /// just waste vertical space.
  static String stripCompletionMarkers(String text) {
    var out = text
        // Strip WRITE_FILE FIRST so we don't accidentally chew on its
        // body if the body happens to contain something that looks
        // like a TASK_COMPLETE / ASK_USER marker.
        .replaceAll(_writeFileStripRe, '')
        .replaceAll(_taskCompleteStripRe, '')
        .replaceAll(_askUserStripRe, '')
        .replaceAll(_useSkillStripRe, '')
        .replaceAll(_webSearchStripRe, '');
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

  // Match the unfinished-marker tail.  We allow a generous body so a
  // partially-streamed marker like `[TASK_COMP`, `[USE_SKILL: my-skill-`,
  // or `[WEB_SEARCH: how to use vim macros in normal mod` is detected
  // BEFORE the closing `]` arrives.  Anchored to end-of-string so we
  // never hide a `[bracket]` earlier in the message that the model
  // already closed.
  //
  // Length history: 30 → 40 (USE_SKILL ids up to 25 chars) → 160
  // (WEB_SEARCH queries can run 100+ chars).  False-positive risk at
  // 160: a long unclosed markdown reference `[Title of an article that
  // ran really long…` would be hidden until its `]` arrives — that's
  // an acceptable trade for never leaking a partial marker into the
  // visible bubble.  Both cases self-heal: the `]` always arrives in
  // the next chunk or two.
  static final RegExp _trailingPartialMarkerRe =
      RegExp(r'\*{0,2}\[[^\]\n]{0,160}$');

  // USE_SKILL / WEB_SEARCH have a variable-length `<id>` / `<query>`
  // portion, so the `startsWith` prefix trick that handles
  // TASK_COMPLETE / ASK_USER doesn't fit them.  We instead check
  // whether the unfinished tail's BODY (after the `[` and optional `*`
  // emphasis) starts with one of these prefixes — covering
  // `[USE_SKILL`, `[USESKILL`, `[USE SKILL`, `[WEB_SEARCH`,
  // `[WEBSEARCH`, `[WEB SEARCH`, etc.  Once these match we hide the
  // tail outright until the closing `]` arrives.
  //
  // Order doesn't matter (we OR-match), but keep the longer alias
  // FIRST so the "is the tail itself shorter than a marker prefix"
  // check fires correctly on early chunks like `[W` or `[U`.
  static const List<String> _variableMarkerBodyPrefixes = [
    'USE_SKILL',
    'USE SKILL',
    'USESKILL',
    'WEB_SEARCH',
    'WEB SEARCH',
    'WEBSEARCH',
    // WRITE_FILE_BEGIN / WRITE_FILE_END / WRITEFILE… aliases.  We only
    // need to register the prefixes the streaming hider checks for —
    // by the time the END marker arrives, the BEGIN body has long
    // since been hidden under the strip pass below, so the END line
    // itself is just visible-noise we tolerate for one chunk.
    'WRITE_FILE',
    'WRITE FILE',
    'WRITEFILE',
  ];

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
        // Same order as the post-stream variant: WRITE_FILE first so
        // its body is removed before TASK/ASK/USE/WEB strip touches
        // anything else.
        .replaceAll(_writeFileStripRe, '')
        .replaceAll(_taskCompleteStripRe, '')
        .replaceAll(_askUserStripRe, '')
        .replaceAll(_useSkillStripRe, '')
        .replaceAll(_webSearchStripRe, '');
    final m = _trailingPartialMarkerRe.firstMatch(out);
    if (m != null) {
      final tail = m.group(0)!.toUpperCase();
      var hide = false;
      // First: TASK_COMPLETE / ASK_USER fixed-form prefix check.
      for (final candidate in _streamingMarkerPrefixes) {
        if (candidate.startsWith(tail)) {
          hide = true;
          break;
        }
      }
      // Then: USE_SKILL / WEB_SEARCH with their variable-length bodies.
      // Strip leading emphasis + `[` from the tail and compare against
      // each marker name — if the tail body starts with (or IS a prefix
      // of) one of the names, hide the tail until the closing `]`
      // arrives.  "Body is a prefix" is what lets us hide `[W` or `[US`
      // early, before the model has finished typing the marker name.
      if (!hide) {
        final body =
            tail.replaceFirst(RegExp(r'^\*{0,2}\['), '');
        for (final p in _variableMarkerBodyPrefixes) {
          if (body.startsWith(p) || p.startsWith(body)) {
            hide = true;
            break;
          }
        }
      }
      if (hide) out = out.substring(0, m.start);
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
  //
  // The prompt is also skill-aware: a `<available_skills>` block is
  // appended whenever SkillService has loaded one or more skills.  The
  // block is rebuilt lazily — the first chat call after [SkillService.init]
  // sees the freshly-populated catalogue, and subsequent calls hit the
  // cache.  Test code can force a rebuild via [refreshSystemPrompt].
  //
  // We cache the LAST-USED variant only.  Most sessions use one
  // enabled-set the entire time, so a single-slot cache hits ~100% in
  // practice.  When the user toggles a skill the cache rebuilds once —
  // still much cheaper than rebuilding every turn.
  static String? _cachedSystemPrompt;
  static Set<String>? _cachedSystemPromptKey;
  // Sentinel that survives a null vs not-set distinction.  A nullable
  // Set<String>? on its own can't tell "I haven't cached anything yet"
  // from "I cached the all-enabled (null whitelist) variant".
  static bool _cachedSystemPromptHasKey = false;
  // Web-search slice of the cache key.  Captured separately (rather
  // than folded into the skill set) because toggling web search must
  // also invalidate, but the two settings are orthogonal — the user
  // can leave skills alone while flipping web search.
  static bool _cachedSystemPromptWebSearch = false;
  // File-write slice of the cache key — same rationale as web search.
  static bool _cachedSystemPromptFileWrite = false;

  /// Build the active system prompt for the given enabled-skill whitelist
  /// and web-search toggle.
  ///
  /// [enabledSkillIds] follows the same semantics as
  /// `AgentConfig.enabledSkills`: null → all skills, non-null → only ids
  /// in the set.  The `<agent_skills>` block is omitted entirely when
  /// no skills end up enabled (saves ~300 tokens AND avoids confusing
  /// the model with a protocol for a feature it can't reach).
  ///
  /// [webSearchEnabled] follows `AgentConfig.webSearchEnabled` —
  /// when false (the default) the `<web_search_tool>` block is omitted
  /// so the model never sees a `[WEB_SEARCH]` marker it can't use.
  /// We do NOT check whether the Brave API key is present here, because
  /// (a) the system prompt is built synchronously on a hot path and
  /// reading the keychain is async, and (b) the agent loop catches a
  /// missing-key error and feeds the model a `[Web search failed]`
  /// envelope that tells it to ask the user — same recovery path as
  /// an expired key, so we don't need to double-gate at prompt time.
  static String systemPromptFor({
    Set<String>? enabledSkillIds,
    bool webSearchEnabled = false,
    bool fileWriteEnabled = false,
  }) {
    if (_cachedSystemPromptHasKey &&
        _setEquals(_cachedSystemPromptKey, enabledSkillIds) &&
        _cachedSystemPromptWebSearch == webSearchEnabled &&
        _cachedSystemPromptFileWrite == fileWriteEnabled) {
      return _cachedSystemPrompt!;
    }
    final built = _buildSystemPrompt(
      enabledSkillIds: enabledSkillIds,
      webSearchEnabled: webSearchEnabled,
      fileWriteEnabled: fileWriteEnabled,
    );
    _cachedSystemPrompt = built;
    _cachedSystemPromptKey =
        enabledSkillIds == null ? null : Set.of(enabledSkillIds);
    _cachedSystemPromptWebSearch = webSearchEnabled;
    _cachedSystemPromptFileWrite = fileWriteEnabled;
    _cachedSystemPromptHasKey = true;
    return built;
  }

  static bool _setEquals(Set<String>? a, Set<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  /// Force the next [systemPromptFor] read to re-evaluate skills / host
  /// info.  Useful for tests, and for any future "reload skills" debug
  /// action.
  static void refreshSystemPrompt() {
    _cachedSystemPrompt = null;
    _cachedSystemPromptKey = null;
    _cachedSystemPromptWebSearch = false;
    _cachedSystemPromptFileWrite = false;
    _cachedSystemPromptHasKey = false;
  }

  // _buildSystemPrompt and its per-block helpers live in
  // `llm_service_prompts.dart` (part of this library).


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

    // Local providers (Ollama et al.) skip the key precondition — see
    // `ProviderConfig.requiresApiKey`.  Use an empty string downstream
    // so the cloud code paths' `Bearer …` builders don't NPE if we ever
    // wire a local provider through them by accident.
    String apiKey = '';
    if (provider.requiresApiKey) {
      final loaded = await ApiKeyStorage.load(provider.id);
      if (loaded == null || loaded.isEmpty) {
        return LlmResponse(
          text: '',
          error: 'API key not configured for ${provider.displayName}.',
        );
      }
      apiKey = loaded;
    }

    final systemPrompt = systemPromptFor(
      enabledSkillIds: config.enabledSkills,
      webSearchEnabled: config.webSearchEnabled,
      fileWriteEnabled: config.fileWriteEnabled,
    );
    try {
      switch (provider.id) {
        case 'claude':
          return _callAnthropic(provider, model, apiKey, messages, systemPrompt);
        case 'gemini':
          return _callGemini(provider, model, apiKey, messages, systemPrompt);
        case 'ollama':
          return _callOllama(provider, model, messages, systemPrompt);
        default:
          // OpenAI-compatible (OpenAI, DeepSeek, etc.) — prefix caching is
          // automatic on these providers (no `cache_control` to set).
          return _callOpenAiCompatible(
              provider, model, apiKey, messages, systemPrompt);
      }
    } catch (e) {
      return LlmResponse(text: '', error: 'Request failed: $e');
    }
  }

  // Provider HTTP and streaming code lives in
  // `llm_service_providers.dart` (part of this library).

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

    // Mirror the non-streaming dispatcher: local providers skip the key
    // pre-flight (see `ProviderConfig.requiresApiKey`).
    String apiKey = '';
    if (provider.requiresApiKey) {
      final loaded = await ApiKeyStorage.load(provider.id);
      if (loaded == null || loaded.isEmpty) {
        throw Exception('API key not configured for ${provider.displayName}.');
      }
      apiKey = loaded;
    }

    final systemPrompt = systemPromptFor(
      enabledSkillIds: config.enabledSkills,
      webSearchEnabled: config.webSearchEnabled,
      fileWriteEnabled: config.fileWriteEnabled,
    );
    switch (provider.id) {
      case 'claude':
        yield* _streamAnthropic(
            provider, model, apiKey, messages, client, systemPrompt);
      case 'gemini':
        yield* _streamGemini(
            provider, model, apiKey, messages, client, systemPrompt);
      case 'ollama':
        yield* _streamOllama(
            provider, model, messages, client, systemPrompt);
      default:
        yield* _streamOpenAi(
            provider, model, apiKey, messages, client, systemPrompt);
    }
  }

}
