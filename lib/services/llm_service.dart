import 'dart:convert';
import 'dart:io';

import '../models/agent_config.dart';
import 'api_key_storage.dart';
import 'skill_service.dart';

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
  static final RegExp _writeFileRe = RegExp(
    r'\[\s*WRITE[_ ]?FILE[_ ]?BEGIN\s*[:=]\s*([^\]\n]+?)\s*\]'
    r'(.*?)'
    r'\[\s*WRITE[_ ]?FILE[_ ]?END\s*\]',
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
  // surfaces that separately, with a diff preview).
  static final RegExp _writeFileStripRe = RegExp(
    r'\*{0,2}\[\s*WRITE[_ ]?FILE[_ ]?BEGIN\s*[:=]\s*[^\]\n]+?\s*\]\*{0,2}'
    r'.*?'
    r'\*{0,2}\[\s*WRITE[_ ]?FILE[_ ]?END\s*\]\*{0,2}',
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

  static String _buildSystemPrompt({
    Set<String>? enabledSkillIds,
    bool webSearchEnabled = false,
    bool fileWriteEnabled = false,
  }) {
    final parts = <String>[_systemPromptBase];
    final enabled = SkillService.filterEnabled(enabledSkillIds);
    if (enabled.isNotEmpty) parts.add(_buildSkillsBlock());
    if (webSearchEnabled) parts.add(_buildWebSearchBlock());
    if (fileWriteEnabled) parts.add(_buildFileWriteBlock());
    parts.add(_buildHostBlock());
    return parts.join('\n\n');
  }

  /// Returns the `<web_search_tool>` block for the system prompt, or an
  /// empty string when the master switch is off.
  ///
  /// Modelled after Cursor's `<web_search_tool>` advertisement — short,
  /// behaviour-focused, with a worked example so the model has a
  /// reference pattern.  We deliberately do NOT name the upstream
  /// provider (Brave) in the prompt: provider portability is a feature
  /// (we may add Tavily / Serper / Perplexity Sonar later), and the
  /// model doesn't care which crawler answers — only what shape its
  /// output arrives in.
  ///
  /// Same marker-style invocation as USE_SKILL — `[WEB_SEARCH: query]`
  /// on its OWN line, intercepted by the agent loop before any shell
  /// command executes.  This keeps the protocol single-format until we
  /// add structured tool_use; once that lands, this block becomes the
  /// human-readable doc for the same tool exposed via the native
  /// channel.
  static String _buildWebSearchBlock() {
    return '''
<web_search_tool>
You have a web-search tool for fetching current information from the public web. To search, emit `[WEB_SEARCH: <query>]` on its OWN line and STOP — the top results arrive as a user-role message in your NEXT turn, in this shape:

[Web search results]
query: "<your query>"
(N results)

1. <title>
   <description>
   <url>  (age: …)
2. …

When to use it:
- The user asks about a topic that is time-sensitive (recent versions, breaking changes, news, prices).
- You need official documentation, API references, or error-message context that bash + local files cannot supply.
- You are about to GUESS at an unfamiliar library / CLI flag / config field — search instead.

When NOT to use it:
- The answer is already in the conversation, in the shell output, or in a loaded skill.
- The question is about THIS host (use `bash` instead — `uname`, `df`, `ps`, etc.).
- Querying private data the user did NOT explicitly ask you to publish.

Turn-shape rules (same as USE_SKILL):
- A `[WEB_SEARCH: <query>]` turn MUST NOT also contain a ```bash block, [TASK_COMPLETE], [ASK_USER], or [USE_SKILL] — the agent loop intercepts the marker BEFORE executing anything, so combining silently drops the command.
- Issue ONE search per turn; iterate based on the results.
- Cite results by index in your ANSWER turn (e.g. "per [3]") so the user can verify the source.
- If the result envelope arrives as `[Web search failed]`, do NOT retry the same query — follow the `recovery` directive in that envelope.

Example INVESTIGATE turn:
  I need the current syntax for the new GitHub Actions cache action.
  [WEB_SEARCH: github actions cache action v4 syntax]
</web_search_tool>''';
  }

  /// Returns the `<file_write_tool>` block for the system prompt, or
  /// an empty string when the master switch is off.
  ///
  /// The tool uses a marker PAIR (`[WRITE_FILE_BEGIN: <path>]` /
  /// `[WRITE_FILE_END]`) with verbatim content in between.  Picked
  /// over a single marker + bash fence because the file content can
  /// itself contain ```bash blocks (think: writing a CI yaml that
  /// embeds shell snippets) — a fence inside a fence is ambiguous and
  /// also collides with the agent loop's `extractCommands` pass.
  ///
  /// Two things this block hammers on:
  ///   1. The Apply button — model MUST understand that the write
  ///      doesn't happen until the user clicks Apply.  Without this
  ///      framing models often emit a follow-up `cat <path>` to verify
  ///      and get confused when the file isn't there yet.
  ///   2. Path absoluteness — the most common write failure is a
  ///      relative path that lands somewhere unexpected (the Flutter
  ///      process CWD, not the terminal's).
  static String _buildFileWriteBlock() {
    return '''
<file_write_tool>
You have a file-write tool for creating or replacing files atomically. To propose a write, emit on its OWN lines:

[WRITE_FILE_BEGIN: <absolute-path>]
<exact file contents — verbatim, NO shell interpretation, NO escaping>
[WRITE_FILE_END]

Then STOP — the user is shown a chat card with a diff preview and MUST click Apply before the bytes hit disk. The outcome arrives as a user-role message in your NEXT turn, in one of these shapes:

[File written]                    [File write rejected by user]      [File write failed]
path: …                           path: …                            path: …
bytes: …                          reason: <free-form>                reason: <kind>
created: true|false               …                                  message: …
mtime: <iso8601>                                                     <recovery hint>

MANDATORY — use [WRITE_FILE_BEGIN] for ALL of these, no exceptions:
- Creating ANY new file (script, source, config, dotfile, snippet).
- Replacing an existing file end-to-end (refactor, regenerate, rewrite).
- ANY time you would otherwise reach for `cat > path`, `cat >> path`, `tee path`, `echo … > path`, `printf … > path`, `python3 -c "open(…)"`, or similar "build a file via shell" tricks.

BANNED — DO NOT emit these as ```bash blocks when the file-write tool is available:
  ❌ cat > path <<'EOF'      ❌ cat <<EOF > path
  ❌ echo "…" > path          ❌ printf "…" > path
  ❌ tee path <<<"…"          ❌ python3 -c "open('path','w').write(…)"
These shell tricks are FRAGILE: heredoc edges break on `EOF` / backticks / `\$` in content, `echo` mangles backslashes, none of them are atomic, and command-safety guards inspect their body and may refuse them. The file-write tool has none of those failure modes — prefer it categorically.

When NOT to use the tool (these are the ONLY exceptions):
- True APPEND to an existing file — use `>>` via bash; this tool only does full replacement.
- Narrow in-place patch of a large file (a few lines in a >1000-line file) — use `sed` / `awk` via bash, OR `cat` the file first and propose a full new version via [WRITE_FILE_BEGIN].
- Anything the user has NOT asked for or implied. File writes are irreversible; when uncertain, [ASK_USER] first.

Hard rules:
- The path MUST be ABSOLUTE. Local: starting with `/` or `~/`. Remote (SSH tab): starting with `/` — `~` does NOT expand over SFTP.
- ONE write proposal per turn. The Apply card needs an individual decision per file.
- A `[WRITE_FILE_BEGIN]` turn MUST NOT also contain a ```bash block, [TASK_COMPLETE], [ASK_USER], [USE_SKILL], or [WEB_SEARCH] — the agent loop intercepts the marker BEFORE running anything, so combining silently drops the command.
- After a `[File write rejected by user]` envelope, DO NOT re-emit the same write for the same path. Either ask the user what to change, propose a different path, or abandon the write.
- After a `[File write failed]` envelope, follow the recovery hint inside it — usually `mkdir -p` first via bash, then re-emit [WRITE_FILE_BEGIN].

Example INVESTIGATE turn (CORRECT — write via tool, run via bash on the next turn):
  I'll create a script that prints prime numbers up to N.
  [WRITE_FILE_BEGIN: /Users/me/primes.py]
  #!/usr/bin/env python3
  import sys
  from sympy import primerange
  for p in primerange(2, int(sys.argv[1])):
      print(p)
  [WRITE_FILE_END]

Counter-example (WRONG — DO NOT do this when the file-write tool is available):
  ```bash
  cat > /Users/me/primes.py << 'PYEOF'
  #!/usr/bin/env python3
  …
  PYEOF
  chmod +x /Users/me/primes.py
  ```
The above is exactly the anti-pattern this tool replaces. Use [WRITE_FILE_BEGIN] for the write, then a SEPARATE bash turn for `chmod +x`.
</file_write_tool>''';
  }

  /// Returns the `<agent_skills>` block for the system prompt, or an
  /// empty string when no skills are enabled.
  ///
  /// Shape, modelled after Cursor's `<agent_skills>` block:
  ///
  /// ```
  /// <agent_skills>
  /// <policy text — when to use, IMMEDIATELY / NEVER directives, turn rules>
  ///
  /// <available_skills>
  /// <agent_skill id="…" path="…">desc</agent_skill>
  /// …
  /// </available_skills>
  /// </agent_skills>
  /// ```
  ///
  /// The catalogue lives INSIDE this block (i.e. inside the system prompt)
  /// rather than as a per-turn `<system-reminder>` user attachment — that
  /// matches how Cursor (and Claude Code's newer builds) ship skills, and
  /// it has three advantages over the old delta-announce design:
  ///
  ///   • Prompt cache: as long as the enabled-skill set is stable the
  ///     entire system prompt is byte-identical, so the Anthropic /
  ///     OpenAI / Google prompt-cache lanes stay warm forever.
  ///   • One source of truth: the model sees the catalogue at the same
  ///     position in every turn, no surprise re-injections, no
  ///     per-conversation `_announcedSkillIds` bookkeeping in the panel.
  ///   • Familiar shape: the `<agent_skill id="…" path="…">desc</agent_skill>`
  ///     entries mirror real-world training data, so smaller open-source
  ///     models parse the listing more reliably than our previous
  ///     `- id: desc` bullet list.
  ///
  /// What we deliberately don't borrow from Cursor: their `Read(path)` tool
  /// call.  ssterm has no tool_use protocol yet, so the model still loads
  /// skill bodies via the `[USE_SKILL: <id>]` marker — the policy section
  /// reflects that.
  static String _buildSkillsBlock() {
    final catalogue = SkillService.buildPromptCatalogue();
    // Defensive: caller only invokes this when SkillService reports at
    // least one enabled skill, but the catalogue can still come back
    // empty (e.g. all entries omitted to fit budget — see
    // [SkillService.buildPromptCatalogue]).  In that edge case we skip
    // the whole block so the model doesn't see an empty container.
    if (catalogue.isEmpty) return '';
    return '''
<agent_skills>
When the user asks you to perform a task, scan the skills below first. A skill is a pre-curated playbook for a common task; loading one usually saves several investigation rounds.

To load a skill, emit `[USE_SKILL: <id>]` on its OWN line and STOP — the full skill body arrives as a user-role message in your NEXT turn. When a skill description matches the task, load it IMMEDIATELY as your first action, BEFORE issuing any investigative commands. NEVER just announce or mention a skill without actually loading it via the marker. Only use skill ids listed below — do not invent or guess ids.

Turn-shape rules:
- A `[USE_SKILL: <id>]` turn MUST NOT also contain a ```bash block, [TASK_COMPLETE], or [ASK_USER] — the agent loop intercepts the marker BEFORE executing anything, so combining them silently drops the command.
- Loading a skill does NOT count as an investigation step. Once the body arrives, resume the normal INVESTIGATE → ANSWER cycle informed by the skill's playbook.
- If no listed skill matches, proceed with normal INVESTIGATE turns.

<available_skills description="Skills the agent can load via [USE_SKILL: <id>]. The `path` attribute is informational — show it to the user when explaining what was loaded.">
$catalogue
</available_skills>
</agent_skills>''';
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
    // OS-specific dialect gotchas — only the tips that apply to THIS host
    // are emitted, so a Linux user doesn't pay tokens for BSD-sed warnings
    // (and vice-versa). Distilled from what used to live in the
    // `local-shell-info` bundled skill; folded in here because
    // (a) host_environment already carries OS/shell, and (b) the bundled
    // skill couldn't reliably distinguish LOCAL vs SSH tabs and would
    // leak macOS-only env data into SSH sessions.
    final dialectTips = switch (os) {
      'macos' =>
        '- LOCAL macOS uses BSD coreutils: `sed -i` REQUIRES a backup-suffix arg (`sed -i \'\' …`); `date -d` is GNU-only (use `date -j -f`); `readlink -f` / `realpath` are not installed by default.\n'
            '- Non-interactive shells (scripts, `sh -c`, `ssh host cmd`) do NOT source `~/.zshrc` / `~/.bashrc` — aliases and functions defined there are unavailable in that context.',
      'linux' =>
        '- LOCAL Linux uses GNU coreutils: `sed -i \'s/a/b/\' f` works without the `\'\'` arg BSD requires. `set -o pipefail` works in bash/zsh but NOT in POSIX `sh`.\n'
            '- Non-interactive shells (scripts, `sh -c`, `ssh host cmd`) do NOT source `~/.bashrc` / `~/.zshrc` — aliases and functions defined there are unavailable in that context.',
      'windows' =>
        '- LOCAL Windows shells (PowerShell, cmd.exe) use different quoting, flag, and pipe semantics from POSIX. Don\'t assume `&&` / `||` / heredocs / back-quotes behave the same. `wsl …` gives a Linux subprocess when the user has WSL installed.',
      _ => '',
    };
    final dialectBlock = dialectTips.isEmpty ? '' : '\n\n$dialectTips';

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

When the active tab is a LOCAL terminal, commands run on THIS host — pick the right tool family (macOS uses BSD `sed` / `awk` / `find`; Linux uses GNU coreutils; Windows may need PowerShell).$dialectBlock

When the active tab is an SSH session, commands run on the REMOTE — if behaviour is OS-specific, run `uname -srm` (or `cat /etc/os-release`) FIRST to detect the remote platform, THEN issue the OS-appropriate command. Do NOT assume the dialect tips above apply to the remote.
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

  // ── OpenAI-compatible (OpenAI, DeepSeek, etc.) ──────────────────────────

  static Future<LlmResponse> _callOpenAiCompatible(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
    String systemPrompt,
  ) async {
    final baseUrl = provider.baseUrl ?? 'https://api.openai.com/v1';
    final url = baseUrl.endsWith('/chat/completions')
        ? baseUrl
        : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
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
  static List<Map<String, dynamic>> _anthropicSystemBlock(String prompt) => [
        {
          'type': 'text',
          'text': prompt,
          'cache_control': {'type': 'ephemeral'},
        },
      ];

  static Future<LlmResponse> _callAnthropic(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
    String systemPrompt,
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
      'system': _anthropicSystemBlock(systemPrompt),
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
    String systemPrompt,
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
        'parts': [{'text': systemPrompt}],
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
      default:
        yield* _streamOpenAi(
            provider, model, apiKey, messages, client, systemPrompt);
    }
  }

  // ── OpenAI / DeepSeek streaming ──────────────────────────────────────

  static Stream<LlmStreamEvent> _streamOpenAi(
    ProviderConfig provider,
    String model,
    String apiKey,
    List<Map<String, String>> messages,
    HttpClient client,
    String systemPrompt,
  ) async* {
    final baseUrl = provider.baseUrl ?? 'https://api.openai.com/v1';
    final url = baseUrl.endsWith('/chat/completions')
        ? baseUrl
        : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

    final isDeepSeek = provider.id == 'deepseek';
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
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
    String systemPrompt,
  ) async* {
    final baseUrl = provider.baseUrl ?? 'https://api.anthropic.com';
    final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/messages';

    final apiMessages = messages.map((m) => {
      'role': m['role'],
      'content': m['content'],
    }).toList();

    final body = {
      'model': model,
      'system': _anthropicSystemBlock(systemPrompt),
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
    String systemPrompt,
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
        'parts': [{'text': systemPrompt}],
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
