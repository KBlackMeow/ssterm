import 'dart:io' show Directory, File, stdout;

import 'package:flutter/services.dart' show rootBundle, AssetManifest;

import '../models/skill.dart';
import '../utils/app_dir.dart';
import 'bundled_skills.dart';

/// Discovers and serves Skills bundled under `assets/skills/<id>/SKILL.md`
/// PLUS dynamically-generated bundled skills registered via
/// [BundledSkillRegistry].
///
/// Lifecycle:
///   • [init] runs ONCE at app boot from `main.dart`, before runApp.  It
///     scans the asset manifest, parses every SKILL.md it finds, and
///     pulls in every dynamic bundled skill registered by that point.
///     This is cheap (a handful of small text files + sync registrations)
///     and removes the need for any async work on the hot LLM call path.
///   • After init, [skills] returns the catalogue synchronously — used
///     by [LlmService] to build the `<available_skills>` block in the
///     system prompt (or, with the system-reminder injection scheme, by
///     the agent loop on first-turn).
///   • [loadBody] returns the body for a given skill id, or null when
///     the id doesn't exist.  For asset skills the body is cached at
///     init; for bundled dynamic skills it's produced on demand (and
///     memoised per-process) so it can include runtime data like the
///     current shell environment.
///   • [buildListingForInjection] formats the catalogue for the model
///     within a token budget — descriptions are truncated to
///     [_maxListingDescChars] and the whole table is capped at
///     [_listingBudgetChars] (matches the Claude Code pattern, which
///     reserves ~1% of context for skill listings).
///
/// Re-init: [init] is idempotent; calling it again forces a re-scan.
/// Useful for tests and (eventually) for a "reload skills" debug action.
class SkillService {
  SkillService._();

  static final List<Skill> _skills = [];
  // Asset-backed AND user-dir-backed bodies share one map — both are
  // pre-read once at init() and cheap to keep in memory (SKILL.md files
  // are kilobytes, not megabytes).
  static final Map<String, String> _assetBodies = {};
  static final Map<String, Future<String> Function()> _bundledBuilders = {};
  // Per-process memo for bundled body builders — once a builder returns
  // its rendered body we cache it for the rest of the session, matching
  // Claude Code's bundled-skill semantics.  Skills that need fresh data
  // per call should re-register on each turn instead.  (No bundled skills
  // ship by default at the moment; see services/bundled_skills.dart.)
  static final Map<String, String> _bundledBodyCache = {};
  static bool _initialized = false;

  /// Per-entry description hard cap. Matches Claude Code's
  /// MAX_LISTING_DESC_CHARS — verbose `when_to_use` strings waste turn-1
  /// cache-creation tokens without improving match rate, so we trim before
  /// they hit the wire.
  static const int _maxListingDescChars = 250;

  /// Overall catalogue budget. Claude Code defaults to ~1% of the context
  /// window (8KB on a 200K-token Sonnet); we hard-code 4KB because the
  /// ssterm bundled set is short and we don't have model-aware sizing yet.
  /// Skills that don't fit are listed name-only at the end.
  static const int _listingBudgetChars = 4 * 1024;

  /// Test-only hook: override the on-disk user-skills directory so unit
  /// tests can point at a temp folder instead of the real `~/.ssterm/skills/`.
  /// Production code leaves this null and falls back to the path derived
  /// from [appBasePath].  Keep it on the static class so we don't have to
  /// thread an extra parameter through every call site.
  static String? debugUserSkillsDirOverride;

  /// Path of the directory ssterm scans for user-installed skills.  Each
  /// child directory is expected to contain a `SKILL.md`, mirroring the
  /// asset bundle layout.  We don't auto-create the directory — its
  /// absence is the user's "I don't use this feature" signal.
  static String get userSkillsDirPath =>
      debugUserSkillsDirOverride ?? '${appBasePath()}/.ssterm/skills';

  /// All discovered skills, in stable id-sorted order so the catalogue
  /// table the model sees doesn't reshuffle between launches.
  static List<Skill> get skills => List.unmodifiable(_skills);

  /// Apply a user-configured whitelist to the installed skill list.
  ///
  /// Semantics (matches AgentConfig.enabledSkills):
  ///   • null whitelist → return ALL installed skills (the default — newly
  ///     installed skills are auto-enabled, which is what users expect
  ///     after dropping a SKILL.md into `~/.ssterm/skills/`).
  ///   • non-null whitelist → return only the subset whose id is in the
  ///     set.  An empty set therefore disables ALL skills.
  ///
  /// Order is preserved — callers feed the result straight into prompt
  /// formatting and the LLM benefits from a stable listing across turns
  /// (better prompt-cache hit rate; less re-explanation overhead).
  static List<Skill> filterEnabled(Set<String>? whitelist) {
    if (whitelist == null) return List.unmodifiable(_skills);
    return _skills
        .where((s) => whitelist.contains(s.id))
        .toList(growable: false);
  }

  /// Compact summary table for system-prompt injection, in the
  /// Cursor-inspired format:
  ///
  /// ```
  /// <agent_skill id="git-bisect" path="assets/skills/git-bisect/SKILL.md">Bisect git history to locate the first bad commit — when the user reports a regression.</agent_skill>
  /// <agent_skill id="verify-fix" path="…">…</agent_skill>
  /// ```
  ///
  /// Each entry: ONE line, opening tag with `id` (used by the model in
  /// `[USE_SKILL: <id>]`) and `path` (informational, lets the user grep /
  /// open the file).  Description goes between the tags; if a separate
  /// `when_to_use` clause exists it's joined with an em-dash so the model
  /// sees both the "what" and the "when".
  ///
  /// We deliberately mirror Cursor's `<agent_skill fullPath=…>desc</agent_skill>`
  /// shape because LLMs trained on Anthropic / OpenAI / Google traces have
  /// seen this format thousands of times and parse it more reliably than
  /// our previous `- id: desc` bullet list — especially small models.
  ///
  /// Returns the empty string when no skills are installed — callers
  /// should also omit the `<available_skills>` wrapper in that case.
  ///
  /// Budget enforcement: each entry costs `~50 chars overhead + desc`;
  /// once we'd exceed [_listingBudgetChars] the tail is collapsed into
  /// one `… (N skills omitted)` line so the model still knows there's
  /// more it can't see right now.
  static String buildPromptCatalogue({Iterable<String>? include}) {
    final pool = include == null
        ? _skills
        : _skills.where((s) => include.contains(s.id)).toList();
    if (pool.isEmpty) return '';

    final rows = <String>[];
    var used = 0;
    var truncated = false;
    for (final s in pool) {
      final row = _formatRow(s);
      // +1 for the newline that will join this row to the next one.
      final rowCost = row.length + 1;
      if (used + rowCost > _listingBudgetChars) {
        truncated = true;
        break;
      }
      rows.add(row);
      used += rowCost;
    }

    if (truncated) {
      final omitted = pool.length - rows.length;
      rows.add(
        '<!-- $omitted skill${omitted == 1 ? '' : 's'} omitted to fit context budget -->',
      );
    }
    return rows.join('\n');
  }

  static String _formatRow(Skill s) {
    final desc = _truncate(s.description, _maxListingDescChars);
    final hint = s.whenToUse;
    final body = (hint == null || hint.isEmpty)
        ? desc
        : '$desc — ${_truncate(hint, _maxListingDescChars)}';
    // Defense in depth: a single deranged row (e.g. user pasted a 10 KB
    // single-line description into frontmatter) must not blow the whole
    // budget by itself.  Truncate the inner body as a last resort BEFORE
    // we wrap it in the XML tag — keeps the tag itself valid.
    final cappedBody = body.length > _maxListingDescChars * 2 + 32
        ? '${body.substring(0, _maxListingDescChars * 2 + 28)}…'
        : body;
    // Escape `"` so a description containing a literal quote can't break
    // the path attribute.  `<` / `&` are left as-is — they would only
    // matter if a SKILL.md author put a literal XML tag in their desc,
    // which we treat as the author's choice (and is in fact common when
    // referencing other tag names in prose).
    final safePath = s.fullPath.replaceAll('"', '&quot;');
    return '<agent_skill id="${s.id}" path="$safePath">$cappedBody</agent_skill>';
  }

  static String _truncate(String s, int cap) {
    if (s.length <= cap) return s;
    // -1 keeps room for the ellipsis so the visible length stays ≤ cap.
    return '${s.substring(0, cap - 1)}…';
  }

  /// Scan `assets/skills/*/SKILL.md`, parse frontmatter, cache bodies,
  /// AND pull in every bundled dynamic skill registered via
  /// [BundledSkillRegistry] up to this point.
  ///
  /// Skills with malformed frontmatter (missing `description`, broken
  /// `---` delimiters, …) are SKIPPED with a `[skill]` log line — they
  /// must not abort startup, because a single bad file would lock the
  /// user out of every other skill.
  static Future<void> init() async {
    _skills.clear();
    _assetBodies.clear();
    _bundledBuilders.clear();
    _bundledBodyCache.clear();

    final collected = <Skill>[];

    // ── Asset-backed skills (static SKILL.md) ──────────────────────────
    final List<String> assetPaths;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      assetPaths = manifest
          .listAssets()
          .where((p) =>
              p.startsWith('assets/skills/') && p.endsWith('/SKILL.md'))
          .toList();
    } catch (e) {
      _log('error scope=manifest msg="$e"');
      _initialized = true;
      return;
    }
    assetPaths.sort();

    // Track per-source loads for the consolidated summary line at the
    // very end of init().  We deliberately DON'T emit one `[skill] loaded
    // id=…` line per skill on the happy path — for a typical install
    // (4 asset + 0 bundled + 0 user) that's 4 lines of "nothing
    // interesting happened" noise on every cold boot.  Skips and errors
    // ARE still logged individually because those are anomalies.
    final assetIds = <String>[];
    final bundledIds = <String>[];
    final userIds = <String>[];

    for (final path in assetPaths) {
      try {
        final raw = await rootBundle.loadString(path);
        final id = _idFromPath(path);
        if (id == null) {
          _log('skip path=$path reason=bad_layout');
          continue;
        }
        final parsed = Skill.tryParse(id: id, assetPath: path, raw: raw);
        if (parsed == null) {
          _log('skip id=$id reason=bad_frontmatter');
          continue;
        }
        collected.add(parsed.skill);
        _assetBodies[id] = parsed.body;
        assetIds.add(id);
      } catch (e) {
        _log('error scope=load path=$path msg="$e"');
      }
    }

    // ── Bundled dynamic skills (Dart functions) ────────────────────────
    for (final def in BundledSkillRegistry.all) {
      // Asset skill of the same id wins (rare but possible if a developer
      // shadows a bundled skill while iterating) — log + skip.
      if (collected.any((s) => s.id == def.id)) {
        _log('skip source=bundled id=${def.id} reason=shadowed_by_asset');
        continue;
      }
      collected.add(def.toSkill());
      _bundledBuilders[def.id] = def.buildBody;
      bundledIds.add(def.id);
    }

    // ── User-dir skills (`~/.ssterm/skills/<id>/SKILL.md`) ─────────────
    //
    // Precedence: ASSET and BUNDLED take priority over USER for the same
    // id.  We log + skip the user file instead of overriding so a typo
    // in the user dir can't silently shadow a tested built-in.  Users
    // who want to customise a built-in skill should pick a NEW id (e.g.
    // `git-bisect-mine`).
    await _scanUserDir(collected, userIds);

    // Stable id-sorted order so prompt cache hits stay warm across boots
    // when the skill set is unchanged.
    collected.sort((a, b) => a.id.compareTo(b.id));
    _skills.addAll(collected);
    _initialized = true;
    // One consolidated summary instead of `loaded …` per skill.  Sources
    // are listed in declaration order so a glance tells you "the asset
    // set + my custom user skills + N bundled".  Empty groups are
    // omitted to keep the line tight on the common all-asset case.
    final parts = <String>['count=${_skills.length}'];
    if (assetIds.isNotEmpty) parts.add('asset=${assetIds.join(",")}');
    if (bundledIds.isNotEmpty) parts.add('bundled=${bundledIds.join(",")}');
    if (userIds.isNotEmpty) parts.add('user=${userIds.join(",")}');
    _log('init done ${parts.join(" ")}');
  }

  /// Walk `~/.ssterm/skills/`, append every well-formed SKILL.md to
  /// [collected], cache the body in [_assetBodies] (shared map: at body-
  /// load time we don't care where the bytes came from), and log every
  /// decision.  Missing dir = no-op.
  static Future<void> _scanUserDir(
    List<Skill> collected,
    List<String> userIds,
  ) async {
    final dirPath = userSkillsDirPath;
    final dir = Directory(dirPath);
    // No-op silently when the dir doesn't exist — that's the default for
    // anyone who hasn't customised skills, so logging it as a "skip"
    // event was pure noise.  An actual scan failure (permission denied,
    // I/O error) still surfaces below.
    if (!await dir.exists()) return;

    final List<Directory> subdirs;
    try {
      subdirs = await dir
          .list(followLinks: false)
          .where((e) => e is Directory)
          .cast<Directory>()
          .toList();
    } catch (e) {
      _log('error scope=user_dir path=$dirPath msg="$e"');
      return;
    }
    // Stable order so logs are reproducible (the OS doesn't guarantee
    // listing order across runs / filesystems).
    subdirs.sort((a, b) => a.path.compareTo(b.path));

    for (final sub in subdirs) {
      final id = sub.uri.pathSegments
          .lastWhere((seg) => seg.isNotEmpty, orElse: () => '');
      if (id.isEmpty) continue;

      if (collected.any((s) => s.id == id)) {
        _log('skip source=user id=$id reason=shadowed_by_${_skillSourceLabelOf(collected, id)}');
        continue;
      }

      final mdFile = File('${sub.path}/SKILL.md');
      if (!await mdFile.exists()) {
        _log('skip source=user id=$id reason=no_skill_md');
        continue;
      }
      try {
        final raw = await mdFile.readAsString();
        final parsed = Skill.tryParse(
          id: id,
          assetPath: mdFile.path,
          raw: raw,
          source: SkillSource.user,
        );
        if (parsed == null) {
          _log('skip source=user id=$id reason=bad_frontmatter');
          continue;
        }
        collected.add(parsed.skill);
        _assetBodies[id] = parsed.body;
        userIds.add(id);
      } catch (e) {
        _log('error scope=user_load id=$id msg="$e"');
      }
    }
  }

  static String _skillSourceLabelOf(List<Skill> pool, String id) {
    final hit = pool.firstWhere(
      (s) => s.id == id,
      orElse: () => const Skill(id: '', name: '', description: ''),
    );
    return hit.source.name;
  }

  /// Returns the SKILL.md body for [id], or null when unknown.
  /// Trimmed — leading/trailing whitespace would otherwise pollute the
  /// `[Skill loaded: …]` injection we send the model.
  ///
  /// For bundled dynamic skills the body is produced by their registered
  /// builder on first request and memoised per-process.
  static Future<String?> loadBody(String id) async {
    final asset = _assetBodies[id];
    if (asset != null) return asset.trim();
    final cached = _bundledBodyCache[id];
    if (cached != null) return cached.trim();
    final builder = _bundledBuilders[id];
    if (builder == null) return null;
    try {
      final body = await builder();
      _bundledBodyCache[id] = body;
      return body.trim();
    } catch (e) {
      _log('error scope=bundled_build id=$id msg="$e"');
      return null;
    }
  }

  /// True once [init] has run.  Mostly useful in tests that want to
  /// assert the boot sequence didn't accidentally skip skill loading.
  static bool get isInitialized => _initialized;

  static String? _idFromPath(String assetPath) {
    const prefix = 'assets/skills/';
    const suffix = '/SKILL.md';
    if (!assetPath.startsWith(prefix) || !assetPath.endsWith(suffix)) {
      return null;
    }
    final id = assetPath.substring(
      prefix.length,
      assetPath.length - suffix.length,
    );
    if (id.isEmpty || id.contains('/')) return null;
    return id;
  }
}

/// Structured one-liner log records, mirroring the format used by the
/// agent loop (`[agent] iter=N …`) so `flutter run` output stays
/// grep-friendly.  All skill-related lines start with `[skill] `.
void _log(String event) => stdout.writeln('[skill] $event');
