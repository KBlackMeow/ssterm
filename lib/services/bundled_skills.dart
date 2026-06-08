import '../models/skill.dart';

/// A skill whose body is produced by a Dart function at load time, NOT
/// read from a static `SKILL.md` asset.  Use this when the playbook
/// needs to embed runtime data the model couldn't know otherwise:
///
///   • The local shell, PATH, locale, OS version.
///   • Paths to user config files (`~/.config/ssterm/...`).
///   • Feature flags or rollout state.
///   • The output of a one-shot probe (`uname -a`, `git --version`).
///
/// Compared to asset-backed skills, bundled dynamic skills:
///   - Cost zero extra bytes in the asset bundle.
///   - Can include LIVE data per session (cached per process).
///   - Cannot be edited without recompiling — they're code.
///
/// Pattern mirrors Claude Code's `registerBundledSkill()` / `getPromptForCommand()`
/// (see `claude-code-source-code/src/skills/bundledSkills.ts`).  The big
/// difference: we don't support per-skill model overrides, `allowed-tools`,
/// or forked execution — those features depend on Claude Code's
/// SkillTool + sub-agent infrastructure which ssterm doesn't have yet.
class BundledSkillDef {
  /// Stable identifier used in `[USE_SKILL: <id>]`.  Must match the
  /// regex `[a-zA-Z0-9._-]+` (the LLM marker grammar).
  final String id;

  /// Human-readable name for any Settings UI.  Defaults to [id] when
  /// not supplied.
  final String name;

  /// WHAT the skill does — shown in both LLM listing and any UI.
  final String description;

  /// WHEN the model should pick this skill, in one phrase.  Shown ONLY
  /// to the LLM, appended to [description] in the catalogue table.
  final String? whenToUse;

  /// Produces the full SKILL.md-equivalent markdown body.  Called at
  /// most once per process (the result is memoised by [SkillService]).
  /// Should be cheap — anything expensive belongs behind an explicit
  /// `await` inside the body itself, not at load time.
  final Future<String> Function() buildBody;

  const BundledSkillDef({
    required this.id,
    String? name,
    required this.description,
    this.whenToUse,
    required this.buildBody,
  }) : name = name ?? id;

  Skill toSkill() => Skill(
        id: id,
        name: name,
        description: description,
        whenToUse: whenToUse,
        // No assetPath — body comes from [buildBody], not the bundle.
        assetPath: null,
        source: SkillSource.bundled,
      );
}

/// Process-wide registry for bundled dynamic skills.  Populated at app
/// startup (before `SkillService.init()`) by calling [register] from a
/// central init point — typically `main.dart`.
///
/// Implementation note: a plain global list is fine here.  The set of
/// bundled skills is fixed at compile time; we don't need dynamic
/// add/remove, hot reload, or sourcing from multiple isolates.  If we
/// ever introduce ssterm "plugins" they'd have their own registry.
class BundledSkillRegistry {
  BundledSkillRegistry._();

  static final List<BundledSkillDef> _defs = [];

  /// Returns all registered bundled skill definitions in registration
  /// order.  [SkillService.init] consumes this and merges them with the
  /// asset-backed catalogue.
  static List<BundledSkillDef> get all => List.unmodifiable(_defs);

  /// Add a new bundled dynamic skill.  Throws when [def.id] collides
  /// with a previously-registered bundled skill — silent shadowing
  /// would be a foot-gun (the same id resolves to different bodies
  /// depending on registration order).  Asset-vs-bundled collisions
  /// are resolved later by [SkillService] (asset wins, with a log).
  static void register(BundledSkillDef def) {
    if (_defs.any((d) => d.id == def.id)) {
      throw StateError('Bundled skill "${def.id}" is already registered.');
    }
    _defs.add(def);
  }

  /// Test-only: wipe the registry so a fresh set of skills can be
  /// installed inside `setUp`.  Never call from production code.
  static void debugReset() {
    _defs.clear();
  }
}

/// Register the default suite of bundled skills that ship with ssterm.
/// Called once from `main.dart` BEFORE `SkillService.init()`.
///
/// Currently EMPTY — the only bundled skill we ever shipped
/// (`local-shell-info`) was removed once we realised the OS / shell /
/// locale data it advertised was already injected via
/// `LlmService._buildHostBlock()` in EVERY system prompt (at the
/// high-weight tail position).  Keeping that data in two places risked
/// the bundled body — captured from the SSTerm process's own
/// `Platform.environment` — leaking macOS values into SSH-tab prompts,
/// since bundled skill bodies are tab-agnostic.
///
/// The registry, [BundledSkillDef], and the dynamic body-builder code
/// path in [SkillService] are kept alive on purpose: they're the right
/// hook for future skills that genuinely need runtime data the asset
/// bundle can't carry (e.g. feature flags, one-shot probe outputs,
/// per-OS install hints that don't fit in the system prompt).  When
/// adding a new bundled skill here:
///   1. Define a private async `_build…Body()` function near the
///      bottom of this file so the registration site stays a one-liner.
///   2. Pick a CONCRETE [whenToUse] string — vague triggers like
///      "when relevant" are useless to the LLM and waste tokens.
///   3. Make sure the body doesn't duplicate anything already in the
///      static system prompt — that's the trap `local-shell-info` fell
///      into.
void registerDefaultBundledSkills() {
  // No bundled skills are shipped by default — see doc comment above.
}
