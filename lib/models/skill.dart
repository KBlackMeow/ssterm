/// Lightweight model for an installed Skill.
///
/// Skills are pre-curated playbooks (the SKILL.md format pioneered by
/// Anthropic / Cursor) that the agent loads ON-DEMAND.  The system prompt
/// only ever advertises the [id] + [description] pair; the full body is
/// streamed into the conversation history exclusively when the model
/// emits `[USE_SKILL: <ID>]` (where ID is the skill's directory name).
/// That progressive-disclosure approach is the
/// whole point of skills — it lets users install dozens of multi-KB
/// playbooks without each one paying a permanent context-window tax.
///
/// Storage layout (per skill):
///
///   `assets/skills/<id>/`
///     SKILL.md          ← REQUIRED, with YAML-style frontmatter:
///                          ---
///                          name: git-bisect
///                          description: One sentence …
///                          ---
///                          (markdown body)
///     anything-else.md  ← OPTIONAL reference docs / scripts the body
///                          can reference (loading those is left to the
///                          caller; SkillService only handles SKILL.md).
class Skill {
  /// Stable identifier used in `[USE_SKILL: <id>]` markers.
  ///
  /// For asset-backed skills this is the parent directory name
  /// (`assets/skills/<id>/SKILL.md`); for bundled dynamic skills it's the
  /// id declared at registration time.  The id is the only filename-safe
  /// slug we trust to be unique across all skill sources, which is why we
  /// don't derive it from frontmatter.
  final String id;

  /// Human-readable name from frontmatter `name:` field (or registration
  /// arg for bundled skills).  Defaults to [id] when missing — the
  /// catalogue still renders fine.
  final String name;

  /// What this skill DOES, in one short clause — surfaced in both the
  /// model-facing listing and any user-facing Settings UI.  Example:
  /// "Bisect git history to locate the first bad commit".
  final String description;

  /// WHEN the model should trigger this skill, in one short clause —
  /// shown ONLY to the model, appended to [description] in the listing
  /// table.  Example: "the user mentions a regression / says 'it used to
  /// work' / asks to bisect history".
  ///
  /// Optional: when null/empty, the listing falls back to `description`
  /// alone.  Splitting the two lets the description stay readable for
  /// humans (UI menu) while the trigger phrasing for the LLM can be much
  /// more explicit — the same trick Claude Code uses with `when_to_use`.
  final String? whenToUse;

  /// Asset path of the SKILL.md file, or null for bundled dynamic skills
  /// whose body is produced by a Dart function instead of a static asset.
  /// SkillService uses this only as a diagnostic; body loading goes
  /// through [SkillService.loadBody].
  final String? assetPath;

  /// Where this skill came from.  Surfaced in the Settings UI so the user
  /// can tell built-in / user-installed apart when they have multiple
  /// skills with similar names.  Not shown to the LLM.
  final SkillSource source;

  const Skill({
    required this.id,
    required this.name,
    required this.description,
    this.whenToUse,
    this.assetPath,
    this.source = SkillSource.asset,
  });

  /// Parse a SKILL.md raw text.  Returns null when the file lacks valid
  /// frontmatter or required fields — SkillService logs and skips those
  /// instead of crashing the whole catalogue load.
  ///
  /// Frontmatter grammar supported (intentionally minimal — no full YAML):
  ///   ---
  ///   key: value
  ///   key: "value with spaces"
  ///   key: 'value'
  ///   ---
  /// Multi-line values, lists, and nested maps are NOT supported.  If we
  /// ever need them we can pull in `package:yaml`, but for `name` +
  /// `description` a 20-line parser keeps the dependency surface flat.
  static SkillParseResult? tryParse({
    required String id,
    required String assetPath,
    required String raw,
    SkillSource source = SkillSource.asset,
  }) {
    // Normalise CRLF so the indexOf below matches on Windows-checked-in files.
    final src = raw.replaceAll('\r\n', '\n');
    if (!src.startsWith('---\n')) return null;
    final endIdx = src.indexOf('\n---', 4);
    if (endIdx == -1) return null;
    final fmRaw = src.substring(4, endIdx);
    // After `\n---` we want to skip the rest of that line (handles trailing
    // newline OR end-of-file without one).
    final afterCloser = endIdx + 4;
    int bodyStart = afterCloser;
    if (bodyStart < src.length && src[bodyStart] == '\n') bodyStart++;
    final body = src.substring(bodyStart);

    final fm = <String, String>{};
    for (final line in fmRaw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final key = line.substring(0, colon).trim();
      var val = line.substring(colon + 1).trim();
      // Strip a single layer of matching ASCII quotes — YAML allows either.
      if (val.length >= 2 &&
          (val.startsWith('"') && val.endsWith('"') ||
              val.startsWith("'") && val.endsWith("'"))) {
        val = val.substring(1, val.length - 1);
      }
      fm[key.toLowerCase()] = val;
    }

    final name = fm['name'] ?? id;
    // Accept three common spellings — YAML community can't agree on which.
    final whenToUse = fm['when_to_use'] ?? fm['when-to-use'] ?? fm['whentouse'];
    var description = fm['description'] ?? '';
    // Fallback (matches Claude Code's loadSkillsDir): when frontmatter
    // omits `description`, lift the first non-heading paragraph from the
    // body.  Less rigid for skill authors — they don't have to repeat
    // their opening sentence in two places.
    if (description.isEmpty) {
      description = _firstParagraph(body);
    }
    if (description.isEmpty) return null;

    return SkillParseResult(
      skill: Skill(
        id: id,
        name: name,
        description: description,
        whenToUse: (whenToUse == null || whenToUse.isEmpty) ? null : whenToUse,
        assetPath: assetPath,
        source: source,
      ),
      body: body,
    );
  }

  /// Extract the first non-empty, non-heading line-block of [body].
  /// We collapse internal whitespace runs so a paragraph that was hard-
  /// wrapped across multiple source lines still renders as one sentence
  /// in the catalogue table.
  static String _firstParagraph(String body) {
    final lines = body.split('\n');
    final buf = StringBuffer();
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        if (buf.isEmpty) continue; // skip leading blanks
        break; // end of first paragraph
      }
      if (line.startsWith('#')) continue; // skip headings
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(line);
    }
    return buf.toString();
  }
}

/// Returned by [Skill.tryParse]: the catalogue entry plus the markdown
/// body so SkillService can cache the body on first load without re-reading
/// the asset.
class SkillParseResult {
  final Skill skill;
  final String body;
  const SkillParseResult({required this.skill, required this.body});
}

/// Where a skill came from.  Mostly diagnostic — surfaced in the Settings
/// UI so the user can tell a built-in `git-bisect` apart from one they
/// dropped into `~/.ssterm/skills/git-bisect/`.
enum SkillSource {
  /// Compiled into the app under `assets/skills/<id>/`.
  asset,

  /// Registered via [BundledSkillRegistry] — body produced by a Dart
  /// function at runtime so it can embed values the static asset bundle
  /// can't carry (feature flags, one-shot probe output, etc.).  No
  /// bundled skills ship by default at the moment; see
  /// `services/bundled_skills.dart` for the registration hook.
  bundled,

  /// Found at `~/.ssterm/skills/<id>/SKILL.md` (or the platform equivalent
  /// returned by `appBasePath()` — Windows uses `%USERPROFILE%`).  Users
  /// can edit these files without rebuilding the app.
  user,
}
