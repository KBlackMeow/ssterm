import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/agent_config.dart';
import 'api_key_storage.dart';

/// One web result row from the Brave Search Web API
/// (`/res/v1/web/search` → `web.results[]`).  Only the fields we
/// actually surface to the LLM are kept — the upstream payload is much
/// richer (favicons, deep links, profile cards, …) but cramming all of
/// that into the prompt blows the context budget for no extra reasoning
/// value.
class BraveSearchResult {
  /// Title shown in SERP — already plain text (Brave strips HTML).
  final String title;

  /// Canonical landing-page URL.  Always absolute http(s).
  final String url;

  /// One- or two-sentence snippet describing the page.  May include
  /// `<strong>` highlight markers in the raw response — we strip those
  /// in [BraveSearchResult.parse] so the LLM doesn't see XHTML noise.
  final String description;

  /// Optional freshness hint Brave attaches to news / blog posts —
  /// e.g. "3 days ago".  Useful for the model to weigh "current
  /// information" vs "stale tutorial".  Null when the upstream
  /// response omitted it.
  final String? age;

  const BraveSearchResult({
    required this.title,
    required this.url,
    required this.description,
    this.age,
  });

  /// Parse one entry from the `web.results[]` array.  Returns null when
  /// the entry is missing the trio (title / url / description) that we
  /// consider the bare minimum to render a usable LLM line.  Defensive
  /// parsing — Brave's schema has been stable in practice, but we'd
  /// rather drop a malformed row than crash the whole search.
  static BraveSearchResult? tryParse(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final title = (raw['title'] as String?)?.trim() ?? '';
    final url = (raw['url'] as String?)?.trim() ?? '';
    final desc = _stripHighlightTags(
      (raw['description'] as String?)?.trim() ?? '',
    );
    if (title.isEmpty || url.isEmpty || desc.isEmpty) return null;
    final age = (raw['age'] as String?)?.trim();
    return BraveSearchResult(
      title: title,
      url: url,
      description: desc,
      age: age == null || age.isEmpty ? null : age,
    );
  }

  /// Brave wraps query-matched terms in `<strong>…</strong>` inside
  /// descriptions so SERP UIs can bold them.  For LLM consumption that's
  /// just XML noise that wastes tokens; strip the tags but keep the
  /// inner text intact.  Also collapse the rare `&amp;` / `&lt;` /
  /// `&gt;` entities Brave emits inside descriptions.
  static String _stripHighlightTags(String s) {
    var out = s
        .replaceAll(RegExp(r'</?strong>'), '')
        .replaceAll(RegExp(r'</?b>'), '')
        .replaceAll(RegExp(r'</?em>'), '');
    out = out
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'");
    return out;
  }
}

/// The category bucket for a [WebSearchException].  Distinct from the
/// HTTP status code so the agent loop can map each kind to a stable
/// user-facing message without re-deriving "what went wrong" from a
/// raw 4xx number.
enum WebSearchErrorKind {
  /// The Brave API key isn't configured (or has been cleared) — the
  /// agent loop should tell the model to ask the user to add one in
  /// Settings.  This is the only kind that's not a transient failure.
  missingKey,

  /// 401 / 403 from Brave.  Usually means the key is invalid or has
  /// been disabled.  Same user-facing remedy as [missingKey] (go to
  /// Settings) but the diagnostic message differs.
  unauthorized,

  /// 429 from Brave (free plan: 1 QPS / 2000 queries per month).
  /// Caller can retry after the suggested cooldown or downgrade to
  /// fewer queries.
  rateLimit,

  /// Network-layer failure — DNS, TCP, TLS, timeout.  Always worth
  /// retrying once, then surface to the user.
  network,

  /// Brave returned a 5xx or a body the parser couldn't recognise.
  /// Should be rare; surface verbatim so we can debug from user
  /// reports.
  server,
}

class WebSearchException implements Exception {
  final WebSearchErrorKind kind;
  final String message;
  final int? statusCode;
  const WebSearchException(this.kind, this.message, {this.statusCode});

  @override
  String toString() =>
      'WebSearchException(${kind.name}${statusCode == null ? '' : ' status=$statusCode'}): $message';
}

/// Thin wrapper over the Brave Web Search API
/// (https://api.search.brave.com/app/documentation/web-search/get-started).
///
/// Why Brave and not Google / Bing / DuckDuckGo:
///   • Independent crawler — does NOT proxy Google results, so it
///     keeps working when Google rate-limits / blocks aggregators.
///   • Free tier: 2,000 queries / month, 1 QPS — enough headroom for
///     a single-user agent without an upfront credit-card requirement.
///   • Privacy: no per-user tracking; we pass `X-Subscription-Token`
///     and Brave aggregates by key, not by user IP.
///
/// Auth: a static `X-Subscription-Token: <key>` header.  We pull the
/// key from [ApiKeyStorage] under [AgentConfig.braveSearchKeyId] so it
/// shares the keychain / file-permissioned storage path with the LLM
/// keys — one less surface to lock down.
class WebSearchService {
  static const _endpoint = 'https://api.search.brave.com/res/v1/web/search';

  /// Hard ceiling on results requested per call.  The Brave API
  /// accepts up to 20 per page; we cap lower because each result eats
  /// 100-300 chars in the LLM injection, and beyond ~10 the model's
  /// attention drops off sharply (every long-context benchmark agrees).
  static const _defaultCount = 10;

  /// Network timeout for the whole HTTP transaction.  Brave's median
  /// latency is ~300ms; the cap is generous to absorb mobile network
  /// jitter without hanging the agent loop.
  static const Duration _timeout = Duration(seconds: 15);

  /// Default budget for the LLM-facing formatted string produced by
  /// [formatForLlm].  Sized to leave headroom for the rest of the
  /// conversation — at 4096 chars we fit ~10 results comfortably while
  /// still leaving ~28 KB of the 32 KB context window free.
  static const _defaultLlmCharBudget = 4096;

  /// Issue ONE web search and return the parsed result list.
  ///
  /// Throws [WebSearchException] for the four documented failure modes
  /// ([WebSearchErrorKind]).  The caller is expected to map those into
  /// user-facing messages — we intentionally don't catch-and-string
  /// here so the agent loop can branch on `e.kind`.
  ///
  /// [count] is clamped to `[1, 20]`.  [country] follows Brave's
  /// 2-letter ISO codes; null falls back to Brave's default which is
  /// "global / English".  We expose it as a knob because tech queries
  /// in non-English locales often surface stale or translated content
  /// when the country isn't pinned to "US".
  ///
  /// [overrideKey] is escape hatch for tests so they don't have to
  /// touch the global [ApiKeyStorage].  Production code leaves it null
  /// — the agent loop ALWAYS reads the key from secure storage.
  static Future<List<BraveSearchResult>> search(
    String query, {
    int count = _defaultCount,
    String? country,
    String? overrideKey,
    HttpClient? httpClient,
  }) async {
    final q = query.trim();
    if (q.isEmpty) {
      throw const WebSearchException(
        WebSearchErrorKind.server,
        'Query is empty.',
      );
    }
    final key =
        overrideKey ?? await ApiKeyStorage.load(AgentConfig.braveSearchKeyId);
    if (key == null || key.isEmpty) {
      throw const WebSearchException(
        WebSearchErrorKind.missingKey,
        'No Brave Search API key configured. Open Settings → Agent → Web search and paste a key from https://api.search.brave.com/app/keys',
      );
    }

    final clampedCount = count.clamp(1, 20);
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: <String, String>{
        'q': q,
        'count': '$clampedCount',
        if (country != null && country.isNotEmpty) 'country': country,
        // `safesearch=moderate` matches what the Brave site does by default
        // and filters egregious NSFW/violent pages.  Off would surface them.
        'safesearch': 'moderate',
        // `text_decorations=false` would suppress the `<strong>…</strong>`
        // highlight tags inside descriptions, but Brave's docs warn it can
        // also drop legit angle brackets in technical content.  We strip
        // tags client-side in [BraveSearchResult.parse] instead.
        'text_decorations': 'true',
      },
    );

    final client = httpClient ?? HttpClient()
      ..connectionTimeout = _timeout;
    HttpClientResponse resp;
    String body;
    try {
      final req = await client.getUrl(uri).timeout(_timeout);
      // Brave requires these THREE headers — the docs are picky.
      // Accept must be JSON or you get an HTML error page (not JSON-parsable).
      req.headers.set('Accept', 'application/json');
      req.headers.set('Accept-Encoding', 'gzip');
      req.headers.set('X-Subscription-Token', key);
      resp = await req.close().timeout(_timeout);
      body = await resp.transform(utf8.decoder).join().timeout(_timeout);
    } on SocketException catch (e) {
      throw WebSearchException(
        WebSearchErrorKind.network,
        'Network error contacting Brave Search: ${e.message}',
      );
    } on TimeoutException {
      throw const WebSearchException(
        WebSearchErrorKind.network,
        'Brave Search request timed out after 15s.',
      );
    } on HttpException catch (e) {
      throw WebSearchException(
        WebSearchErrorKind.network,
        'HTTP error contacting Brave Search: ${e.message}',
      );
    } finally {
      // Only close the client we created — if the caller passed one,
      // it owns the lifecycle.  Closing a borrowed client would break
      // test fixtures that reuse it across multiple queries.
      if (httpClient == null) client.close(force: true);
    }

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebSearchException(
        WebSearchErrorKind.unauthorized,
        'Brave Search rejected the API key (status ${resp.statusCode}). Check Settings → Agent → Web search.',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode == 429) {
      throw WebSearchException(
        WebSearchErrorKind.rateLimit,
        'Brave Search rate limit hit (status 429). Free plan is 1 QPS / 2000 queries per month.',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw WebSearchException(
        WebSearchErrorKind.server,
        'Brave Search returned status ${resp.statusCode}: ${_truncate(body, 200)}',
        statusCode: resp.statusCode,
      );
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      throw WebSearchException(
        WebSearchErrorKind.server,
        'Brave Search returned malformed JSON: $e',
      );
    }

    final web = json['web'];
    if (web is! Map<String, dynamic>) {
      // Brave returns `web` absent when the query matched ZERO web pages
      // (it might still have FAQ / news / discussions blocks).  Treat
      // "no web results" as an empty list, not an error — the LLM can
      // then either re-query or tell the user.
      return const [];
    }
    final results = web['results'];
    if (results is! List) return const [];
    return results
        .map(BraveSearchResult.tryParse)
        .whereType<BraveSearchResult>()
        .toList(growable: false);
  }

  /// Render [results] into the markdown blob we inject as the next
  /// user-role message.  Shape:
  ///
  /// ```
  /// [Web search results]
  /// query: "<query>"
  /// (N results)
  ///
  /// 1. <title>
  ///    <description>
  ///    <url>  (age: …)
  ///
  /// 2. …
  /// ```
  ///
  /// Why this exact shape:
  ///   • The `[Web search results]` header mirrors `[Command executed]`
  ///     and `[Skill loaded]` envelopes elsewhere in the loop, so the
  ///     model has a uniform "this is tool output" cue.
  ///   • Numbered list (not bulleted) so the model can refer to results
  ///     by index ("source [3] says…") in its ANSWER turn.
  ///   • URL on its own line at the end so a future "open this in a
  ///     browser" UI hook can extract it via simple regex.
  ///   • Description on a separate line so wrapping in the chat bubble
  ///     doesn't visually fuse it with the URL.
  ///
  /// Tokens are scarce, so the output is truncated to [budgetChars] —
  /// when we hit the cap mid-list, we emit a `…(N more omitted)` line
  /// so the model knows there ARE more results it could ask about.
  static String formatForLlm(
    String query,
    List<BraveSearchResult> results, {
    int budgetChars = _defaultLlmCharBudget,
  }) {
    if (results.isEmpty) {
      return '[Web search results]\nquery: "${_quoteSafe(query)}"\n(0 results — try a broader query or check spelling)';
    }
    final buf = StringBuffer()
      ..writeln('[Web search results]')
      ..writeln('query: "${_quoteSafe(query)}"')
      ..writeln('(${results.length} results)')
      ..writeln();

    var emitted = 0;
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      // Per-result rendering — keep titles intact (signal), trim long
      // descriptions (noise), append age on the URL line when present.
      final desc = _truncate(r.description, 280);
      final ageSuffix = r.age == null ? '' : '  (age: ${r.age})';
      final entry = StringBuffer()
        ..writeln('${i + 1}. ${_truncate(r.title, 160)}')
        ..writeln('   $desc')
        ..writeln('   ${r.url}$ageSuffix')
        ..writeln();
      // +1 for the trailing implicit newline already on each entry.
      if (buf.length + entry.length > budgetChars) {
        // Bail out BEFORE writing the next entry; emit a clear "rest
        // omitted" footer so the model can request more if it needs
        // to (e.g. "summarise sources 4-10" in a follow-up search).
        final omitted = results.length - emitted;
        buf.writeln(
          '… ($omitted more result${omitted == 1 ? '' : 's'} omitted to fit context budget)',
        );
        break;
      }
      buf.write(entry);
      emitted++;
    }
    return buf.toString().trimRight();
  }

  /// Format a [WebSearchException] for injection into the conversation
  /// as the next user-role message.  Separate from [formatForLlm] so
  /// the agent loop can reuse it without first wrapping the exception
  /// in a synthetic empty-result list.
  static String formatErrorForLlm(String query, WebSearchException e) {
    // The `recovery` hint matches the [WebSearchErrorKind] semantics —
    // it tells the model what to DO instead of just what went wrong,
    // which prevents the agent from blindly retrying a query that
    // failed for a permanent reason (no key, bad key).
    final recovery = switch (e.kind) {
      WebSearchErrorKind.missingKey =>
        'Web search is not configured. Tell the user to open Settings → Agent → Web search and paste a Brave Search API key, then proceed without web_search. Do NOT retry the same web_search tool call.',
      WebSearchErrorKind.unauthorized =>
        'The stored Brave Search API key was rejected. Tell the user to update the key in Settings, then proceed without web_search. Do NOT retry the same web_search tool call.',
      WebSearchErrorKind.rateLimit =>
        'Rate-limited by Brave Search. Wait ~60s OR continue without web search.',
      WebSearchErrorKind.network =>
        'Network failed mid-search. You may retry the same web_search tool call ONCE; if it fails again, proceed without it.',
      WebSearchErrorKind.server =>
        'Brave Search returned an unexpected response. Proceed without web search.',
    };
    return '[Web search failed]\n'
        'query: "${_quoteSafe(query)}"\n'
        'reason: ${e.kind.name}\n'
        'message: ${e.message}\n\n'
        '$recovery';
  }

  static String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max - 1)}…';
  }

  /// Escape `"` inside the user's query so the `query: "<…>"` line in
  /// the LLM envelope stays unambiguous when the query itself contains
  /// quote characters.  Backslash + quote matches typical YAML/JSON
  /// escaping which the model has seen in training.
  static String _quoteSafe(String s) => s.replaceAll('"', r'\"');
}
