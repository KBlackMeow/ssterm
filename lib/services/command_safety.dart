/// Pre-flight safety check for commands the agent wants to send to the
/// shell.
///
/// Rejection reasons:
///   1. Background EOL `&` — output leaks past our OSC 133 D capture
///      window so the next capture is corrupted.
///   2. Always-interactive programs (`vim`, `less`, `top`, …) — block the
///      agent loop until the user manually exits.
///   3. REPLs (`python`, `node`, …) invoked WITHOUT a script / `-c`
///      argument — same blocking problem.  Note: `python3 -c "…"`,
///      `python3 script.py`, `node -e "…"` are all NON-interactive and
///      explicitly allowed; the previous version blocked them, which is
///      what made the LLM hit a wall when it had already chosen the
///      correct non-interactive form.
///   4. Database CLIs (`mysql`, `psql`, `redis-cli`, …) without an
///      execute / file / command argument — same problem.
///   5. `tail -f` / `watch` — block indefinitely.
///
/// All checks scan EVERY line of [cmd] so a multi-line script can't
/// smuggle a blocked program in by hiding it after a newline.
///
/// Pure static API — no Flutter / dart:io dependency, fully unit-testable.
library;

import '../models/agent_config.dart' show DangerousCommandsPolicy;

// ── Dangerous-command classifier ─────────────────────────────────────────
//
// A SECOND, independent layer on top of [CommandSafety.reason].  The
// existing `reason()` is operational ("will this hang the agent loop?");
// `danger()` below is intent-based ("would running this likely destroy
// data?").  We keep them split because:
//
//   • The agent loop wants different recovery for each — `reason()`
//     returns a self-correction envelope to the LLM, `danger()` triggers
//     a user-facing confirmation card.
//   • Disabling all dangerous-command rules (or even loading a malformed
//     custom one) must NEVER weaken the operational safety net.

/// Structured verdict returned by [CommandSafety.danger].  Carries the
/// rule's id (for logs) and a one-line label (for the chat card /
/// confirmation modal) so the caller doesn't need to look the rule up
/// again.
class DangerVerdict {
  /// Rule id.  Built-in ids are prefixed `builtin:` (e.g.
  /// `builtin:rm-rf-root`); user custom rules use their stored uuid
  /// (no prefix).  Stable across releases so log greps survive.
  final String patternId;

  /// One-line human-readable description of WHY this command is
  /// dangerous.  Shown in the confirmation UI.
  final String label;

  /// Source of the rule.  Useful for the Settings UI's "this fired"
  /// telemetry (future) and for logs.
  final DangerRuleSource source;

  const DangerVerdict({
    required this.patternId,
    required this.label,
    required this.source,
  });
}

enum DangerRuleSource { builtin, custom }

/// Built-in rule definition.  Kept private — external callers see only
/// the [DangerVerdict].  The `id` is stamped into [DangerVerdict.patternId]
/// with a `builtin:` prefix so it can never collide with a user's
/// custom-pattern uuid.
class _BuiltinDangerRule {
  final String id;
  final String label;
  final String pattern;
  const _BuiltinDangerRule(this.id, this.label, this.pattern);
}

/// Initial built-in rule set.  Designed for HIGH precision on obvious
/// destructive intent, not exhaustive coverage — every entry below
/// either wipes data, hands the box to a remote script, or shuts the
/// system off.  Lower-precision rules (e.g. "any rm -rf anywhere")
/// would generate too many false positives for legitimate workflows
/// (`rm -rf node_modules`) and erode the user's trust in the prompt.
///
/// Adding a rule:
///   1. Pick a stable kebab-case id (becomes `builtin:<id>`).  Never
///      rename — that would silently re-enable a rule the user had
///      disabled via [DangerousCommandsPolicy.disabledBuiltins].
///   2. Write the regex assuming the FULL line as candidate.  Multi-
///      line input is split per-line by [CommandSafety.danger] before
///      matching, so `^`/`$` anchor to a single command line.
///   3. Prefer permissive regexes with the confirmation as the safety
///      net (a false positive = one extra click).  False NEGATIVES
///      (genuine destruction not caught) are the bug we care about.
const List<_BuiltinDangerRule> _builtinDangerRules = [
  // `rm -rf /` and its sloppy-flag variants (`-fR`, `-r -f`, `-Rfv`).
  _BuiltinDangerRule(
    'rm-rf-root',
    'Recursive force-delete of / (root filesystem)',
    r'\brm\s+(?:-\S+\s+)*-\S*[rR]\S*(?:\s+-\S+)*\s+/(?:\s|\*|/|$)',
  ),
  // `rm -rf $HOME` / `~` — wipes the user's home directory.  We do not
  // try to resolve $HOME to a literal path; matching the literal token
  // is enough because both shells expand it BEFORE running the command,
  // so the token "$HOME" / "~" can only appear pre-expansion.
  _BuiltinDangerRule(
    'rm-rf-home',
    'Recursive force-delete of \$HOME (entire home directory)',
    r'\brm\s+(?:-\S+\s+)*-\S*[rR]\S*(?:\s+-\S+)*\s+(?:\$HOME|~)(?:\s|\*|/|$)',
  ),
  // `dd ... of=/dev/sda` — raw-write to a block device, instantly
  // wipes the partition table.
  _BuiltinDangerRule(
    'dd-block-device',
    'dd writing directly to a block device',
    r'\bdd\b[^|;&\n]*\bof=/dev/(?:sd[a-z]|hd[a-z]|nvme\d+n\d+|disk\d+|mmcblk\d+)',
  ),
  // `mkfs.*` on /dev/... — reformats the filesystem.
  _BuiltinDangerRule(
    'mkfs',
    'Reformatting a filesystem',
    r'\bmkfs(?:\.\w+)?\s+(?:-\S+\s+)*/dev/\S+',
  ),
  // Classic fork bomb.  Exact-shape match — the bracketed form has
  // essentially no legitimate use outside teaching examples.
  _BuiltinDangerRule(
    'fork-bomb',
    'Fork bomb (recursive self-spawn until OS limits hit)',
    r':\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:',
  ),
  // `chmod -R 777 /` / `chmod 777 /` — world-writable on root.
  _BuiltinDangerRule(
    'chmod-permissive-root',
    'Making the root filesystem world-writable',
    r'\bchmod\s+(?:-\S+\s+)*[0-7]?777\s+/(?:\s|\*|/|$)',
  ),
  // Redirecting output to a raw block device — corrupts the disk.
  _BuiltinDangerRule(
    'redirect-to-block-device',
    'Redirecting output to a raw disk device',
    r'>\s*/dev/(?:sd[a-z]|hd[a-z]|nvme\d+n\d+|disk\d+|mmcblk\d+)',
  ),
  // `curl ... | sh` — execute untrusted remote script with shell
  // privileges.  Covers wget too.  Also flags `| sudo bash` etc.
  _BuiltinDangerRule(
    'curl-pipe-shell',
    'Piping a remote download straight into a shell',
    r'\b(?:curl|wget|fetch)\b[^|]*\|\s*(?:sudo\s+)?(?:bash|sh|zsh|fish|ksh)(?:\s|$)',
  ),
  // System shutdown / reboot.  Catches `shutdown -h now`, `reboot`,
  // `halt`, `poweroff`, `init 0`, `init 6`, `systemctl poweroff`, etc.
  _BuiltinDangerRule(
    'shutdown-or-reboot',
    'System shutdown / reboot',
    r'\b(?:shutdown|halt|poweroff|reboot|init\s+[06]|systemctl\s+(?:halt|poweroff|reboot))\b',
  ),
  // Git force-push — overwrites remote history, can lose teammates'
  // commits.  Explicitly carve out the safe variants `--force-with-lease`
  // and `--force-if-includes` (whose entire reason for existing is to be
  // a non-destructive force-push).  `-f` short form is matched with a
  // word-boundary so `--force-with-lease` doesn't accidentally trigger
  // the short-flag branch.
  _BuiltinDangerRule(
    'git-push-force',
    'Git force push (overwrites remote history)',
    r'\bgit\s+push\b(?:\s+\S+)*\s+(?:-f\b|--force(?!-with-lease|-if-includes)\b)',
  ),
  // Git hard reset — discards uncommitted changes in index + worktree.
  // Common agent footgun: model "fixes" a state mismatch by hard-
  // resetting and silently wipes the user's WIP.
  _BuiltinDangerRule(
    'git-reset-hard',
    'Git hard reset (discards uncommitted changes)',
    r'\bgit\s+reset\b(?:\s+\S+)*\s+--hard\b',
  ),
  // `git clean -f` permanently removes UNTRACKED files (anything not in
  // .gitignore + not in the index).  No git reflog to undo from.
  _BuiltinDangerRule(
    'git-clean-force',
    'Git clean -f (permanently deletes untracked files)',
    r'\bgit\s+clean\b(?:\s+\S+)*\s+-\S*f\S*',
  ),
  // Git history rewrite tools.  Even a "successful" run leaves dangling
  // SHAs that stale clones can re-push, and signed-commit metadata is
  // destroyed irreversibly.
  _BuiltinDangerRule(
    'git-history-rewrite',
    'Git history rewrite (filter-branch / filter-repo)',
    r'\bgit\s+(?:filter-branch|filter-repo)\b',
  ),
  // `find … -delete` is `rm -rf` wearing a fake moustache.  Same
  // recursive blast radius, but lexically nothing like `rm` so our
  // existing rules miss it.
  _BuiltinDangerRule(
    'find-delete',
    '`find -delete` (recursive deletion via find)',
    r'\bfind\b[^|;&\n]*\s-delete\b',
  ),
  // `chown -R` on root filesystem — symmetric with `chmod 777 /`.
  // Even a non-malicious recursive chown of `/` breaks every setuid
  // binary on the system and locks out the original owner.
  _BuiltinDangerRule(
    'chown-recursive-root',
    'Recursive chown of / (root filesystem)',
    r'\bchown\s+(?:-\S+\s+)*-\S*[rR]\S*(?:\s+-\S+)*\s+\S+\s+/(?:\s|\*|/|$)',
  ),
  // IaC teardown.  `terraform destroy` / `pulumi destroy` happily wipe
  // production infrastructure — and there's no "undo", just re-apply
  // and pray the state file is still in sync.
  _BuiltinDangerRule(
    'iac-destroy',
    'Tearing down infrastructure (terraform / pulumi destroy)',
    r'\b(?:terraform|pulumi)\s+destroy\b',
  ),
  // Bulk S3 deletion.  `aws s3 rm --recursive` wipes a prefix; `aws s3
  // rb --force` deletes the bucket AND all objects.  Versioned buckets
  // give you a recovery window, unversioned ones do not.
  _BuiltinDangerRule(
    'aws-s3-recursive-delete',
    'Recursive S3 delete (rm --recursive / rb --force)',
    r'\baws\s+s3\s+(?:rm|rb)\b(?:\s+\S+)*\s+(?:--recursive|--force)\b',
  ),
  // Cluster-wide / namespace-wide kubectl delete.  `delete --all`
  // tears down everything of a kind, `delete namespace foo` wipes
  // every resource in the namespace.
  _BuiltinDangerRule(
    'kubectl-delete-all',
    'Cluster- or namespace-wide kubectl delete',
    r'\bkubectl\s+delete\b(?:\s+\S+)*\s+(?:--all\b|--all-namespaces\b|namespace\b)',
  ),
  // Docker prune.  `system prune -a` removes ALL unused images, not
  // just dangling ones; `volume prune` deletes persistent data.  Both
  // are irreversible.
  _BuiltinDangerRule(
    'docker-prune-all',
    'Docker prune (removes all images / volumes)',
    r'\bdocker\s+(?:system\s+prune\b(?:\s+\S+)*\s+-\S*a\S*|volume\s+prune\b)',
  ),
  // `kill -9 1` (PID 1 = init) hangs the box; `kill -9 -1` SIGKILLs
  // every process the caller owns (including the shell itself).
  // Negative lookahead `(?!\d)` distinguishes `1` from `12`, `123`, …
  _BuiltinDangerRule(
    'kill-init-or-all',
    'Killing PID 1 (init) or every process (-1)',
    r'\bkill\s+(?:-\S+\s+)*-?1(?!\d)',
  ),
  // `redis-cli FLUSHALL` / `FLUSHDB` — one-shot DB wipe.  The
  // operational-safety layer lets `redis-cli <subcommand>` through
  // (it exits cleanly, doesn't block the agent loop) but the intent
  // layer must still flag it.
  _BuiltinDangerRule(
    'redis-flush',
    'Redis FLUSHALL / FLUSHDB (wipes Redis data)',
    r'\bredis-cli\b[^|;&\n]*\bflush(?:all|db)\b',
  ),
];

/// Compiled-regex cache for both built-ins and user-defined patterns.
/// Keyed by pattern source string — same pattern across multiple rules
/// (custom users re-typing a builtin) shares one [RegExp] instance.
/// Capacity is unbounded but in practice tops out at low-double-digits
/// (10 built-ins + however many custom rules the user typed); a real
/// LRU is overkill.
final Map<String, RegExp> _dangerRegexCache = <String, RegExp>{};

RegExp? _compileDanger(String pattern) {
  final cached = _dangerRegexCache[pattern];
  if (cached != null) return cached;
  try {
    final r = RegExp(pattern, caseSensitive: false);
    _dangerRegexCache[pattern] = r;
    return r;
  } catch (_) {
    // Malformed user regex.  Silently skip — a Settings-UI edit-time
    // validator should have caught it, but defence in depth: one bad
    // rule must NOT take down the classifier (which would let every
    // subsequent command through unchecked).
    return null;
  }
}

class CommandSafety {
  /// Programs that are ALWAYS interactive — there is no flag combination
  /// that makes them exit on their own.  Block unconditionally.
  static const _alwaysInteractive = {
    'vim', 'vi', 'nvim', 'emacs', 'nano', 'pico',
    'less', 'more', 'man', 'info',
    'top', 'htop', 'btop', 'atop',
    'tmux', 'screen', 'mc', 'ranger', 'lf',
    'telnet', 'ftp', 'sftp',
  };

  /// Synthetic envelope text returned when the active terminal is in an
  /// alternate-screen application (vim / less / tmux / htop / …).
  ///
  /// Lives here — next to the `_alwaysInteractive` list — so the
  /// "what counts as a TUI" policy stays in one file.  The actual
  /// detection (xterm's `Terminal.isUsingAltBuffer`) is performed at
  /// the call site in `_executeAndCapture`: this string is pure data
  /// so the LLM-facing wording can be regression-tested without
  /// spinning up a Terminal instance.
  static const altScreenReason =
      'Terminal is in an alternate-screen application '
      '(vim / less / tmux / htop / etc). Agent commands would be '
      'interpreted as keystrokes inside that program instead of being '
      'run by the shell. Ask the user to exit the program '
      '(e.g. `:q` in vim, `q` in less, `Ctrl-B d` in tmux) before '
      'retrying. Do NOT retry until they confirm.';

  /// Language REPLs.  Interactive iff invoked WITHOUT any positional /
  /// `-c` / `-e` / `-m` argument, OR with an explicit `-i` /
  /// `--interactive` flag.
  static const _repls = {
    'python', 'python3', 'node', 'irb', 'ipython', 'pry', 'lua', 'ghci',
  };

  /// Database CLIs.  Interactive iff no execute mechanism is provided
  /// (per-CLI rules — see [_dbCliIsInteractive]).
  static const _dbClis = {
    'mysql', 'psql', 'redis-cli', 'mongo', 'mongosh', 'sqlite3',
  };

  // Background EOL `&` — but NOT `&&` (logical AND) and NOT escaped `\&`.
  static final _bgRe = RegExp(r'(?<!\\)(?<!&)&\s*$');
  static final _tailFollowRe = RegExp(r'\btail\s+(?:-\S*f\S*|--follow\b)');
  static final _watchRe = RegExp(r'^\s*watch\b');

  /// Returns a human-readable reason iff [cmd] must be rejected before
  /// being sent to the shell.  Otherwise returns null.
  static String? reason(String cmd) {
    final s = cmd.trim();
    if (s.isEmpty) return null;

    for (final raw in s.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (_bgRe.hasMatch(line)) {
        return 'Background commands ("…&") are not supported by the agent — '
            'OSC 133 D fires the moment the foreground job exits, so the '
            'real output (still being produced by the backgrounded process) '
            'leaks into the NEXT capture and corrupts it. '
            'Use `nohup … > /tmp/out.log 2>&1 & disown` and then read '
            '/tmp/out.log on a later turn.';
      }

      // Defence in depth: a parser crash MUST NOT propagate up — the agent
      // loop's only recovery is to mark the command failed, which derails
      // the whole conversation.  Treat parse failure as "no recognised
      // program on this line" and move on; worst case is a borderline
      // command slipping through to the shell, which is preferable to
      // hanging the loop with an unhandled exception.
      String? name;
      List<String> args;
      try {
        final inv = parseInvocation(line);
        name = inv.name;
        args = inv.args;
      } catch (_) {
        name = null;
        args = const [];
      }

      if (name != null) {
        if (_alwaysInteractive.contains(name)) {
          return '"$name" is interactive and will block the agent loop — '
              'no OSC 133 D will fire until the user manually exits it. '
              'Use a non-interactive equivalent: '
              '`cat`/`grep` instead of `less`/`more`, '
              '`ps`/`pgrep` instead of `top`, '
              '`man -P cat <topic>` to dump a man page.';
        }
        if (_repls.contains(name) && _replIsInteractive(args)) {
          return '"$name" with no script / `-c` / `-m` argument drops into '
              'an interactive REPL and will block the agent loop. '
              'Use `$name -c "…"` to run a one-shot snippet, '
              'or `$name path/to/script.py` to run a file.';
        }
        if (_dbClis.contains(name) && _dbCliIsInteractive(name, args)) {
          return '"$name" without an execute flag opens an interactive '
              'session and will block the agent loop. '
              '${_dbCliExampleHint(name)}';
        }
      }

      if (_tailFollowRe.hasMatch(line)) {
        return '`tail -f` blocks indefinitely. '
            'Use `tail -n N <file>` for a one-shot read.';
      }
      if (_watchRe.hasMatch(line)) {
        return '`watch` blocks indefinitely. '
            'Run the inner command directly once instead.';
      }
    }

    return null;
  }

  /// Classify [cmd] against the dangerous-command blacklist defined by
  /// [policy].  Returns the FIRST matching rule (custom rules checked
  /// before built-ins, so a user pattern can deliberately mask a
  /// built-in label), or null if nothing matched.
  ///
  /// Multi-line input is scanned per-line so a pasted script can't
  /// hide `rm -rf /` behind earlier benign lines.  Empty / whitespace
  /// input short-circuits to null.
  ///
  /// Designed to be called on the hot path (every Enter / every
  /// agent command), so:
  ///   • Regex compilation goes through [_compileDanger]'s cache —
  ///     each rule compiles once per process.
  ///   • Loop short-circuits on the first hit via [RegExp.firstMatch]
  ///     (NOT `allMatches`), so common-case "safe command" pays for
  ///     at most one full pass over the rule list.
  ///   • A malformed user pattern is skipped silently rather than
  ///     bubbling an exception — the classifier MUST be infallible
  ///     for the gate's invariant ("never silently let a forbidden
  ///     line through") to hold.
  static DangerVerdict? danger(String cmd, DangerousCommandsPolicy policy) {
    final trimmed = cmd.trim();
    if (trimmed.isEmpty) return null;

    final lines = trimmed.split('\n');

    // Custom patterns first so a user can override a built-in's wording
    // by adding a rule with the same regex (matches first → wins).
    // Enabled-flag check happens here, not inside the inner loop, so a
    // disabled rule never even pays for `firstMatch`.
    for (final cp in policy.customPatterns) {
      if (!cp.enabled) continue;
      final re = _compileDanger(cp.pattern);
      if (re == null) continue;
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (re.firstMatch(line) != null) {
          return DangerVerdict(
            patternId: cp.id,
            label: cp.label.isEmpty ? cp.pattern : cp.label,
            source: DangerRuleSource.custom,
          );
        }
      }
    }

    for (final rule in _builtinDangerRules) {
      // Built-ins disabled via [DangerousCommandsPolicy.disabledBuiltins]
      // are skipped here — same place as `enabled` for custom rules so
      // disabled rules cost a Set lookup, not a regex pass.
      if (policy.disabledBuiltins.contains(rule.id)) continue;
      final re = _compileDanger(rule.pattern);
      if (re == null) continue;
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (re.firstMatch(line) != null) {
          return DangerVerdict(
            patternId: 'builtin:${rule.id}',
            label: rule.label,
            source: DangerRuleSource.builtin,
          );
        }
      }
    }

    return null;
  }

  /// All built-in rule ids paired with their labels.  Exposed for the
  /// Settings UI so it can render a per-rule toggle list without the
  /// classifier's internals leaking out.  Order is the source-code
  /// order in [_builtinDangerRules] — stable, suitable for stable UI
  /// keys.
  static List<({String id, String label})> get builtinDangerRules => [
        for (final r in _builtinDangerRules) (id: r.id, label: r.label),
      ];

  /// Compile-check a candidate regex.  Used by the Settings UI's
  /// edit-time validator: returns true iff the pattern would actually
  /// be honoured at runtime (i.e. doesn't throw at construction).
  ///
  /// Side effect: caches the compiled regex, so the very next runtime
  /// call to [danger] with this pattern is already warm.  That's
  /// intentional — users typically run the new rule against a test
  /// input immediately after saving it.
  static bool isValidDangerRegex(String pattern) =>
      _compileDanger(pattern) != null;

  /// Splits [line] into the effective program name and its remaining
  /// argument tokens, after stripping `VAR=val` assignments and well-known
  /// wrappers (`sudo`, `env`, `nohup`, `timeout 5`, …).
  ///
  /// Returns `(name: null, args: [])` if no recognisable program is found
  /// (empty input, pure variable assignment, etc.).
  ///
  /// This deliberately handles ONLY simple, unquoted prefixes.  A truly
  /// adversarial input like `bash -c 'vim foo'` cannot be caught here
  /// without a real shell parser — but the agent's own
  /// `_toSingleShellLine` is the only thing that emits `bash -c` and it
  /// runs AFTER this check.
  ///
  /// Visible for unit testing.
  static ({String? name, List<String> args}) parseInvocation(String line) {
    final all = _tokenise(line.trimLeft());
    var i = 0;

    while (i < all.length) {
      final tok = all[i];
      // `VAR=value` env assignment (POSIX prefix form).
      if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=\S*$').hasMatch(tok)) {
        i++;
        continue;
      }
      // Strip the basename of the token so `/usr/bin/sudo` still matches.
      final wrapName = _basename(tok);
      final valueFlags = _wrapperValueFlags[wrapName];
      if (valueFlags != null) {
        i++;
        // Consume the wrapper's own flags (and their values where known).
        while (i < all.length) {
          final f = all[i];
          if (f == '--') {
            // POSIX end-of-options marker.  Everything after is the
            // wrapped program — stop consuming wrapper-flags.
            i++;
            break;
          }
          if (f.startsWith('-')) {
            i++;
            // `-u` (separate-arg form) → also skip the value.  `-u=alice`
            // (joined form) was already consumed above.
            if (valueFlags.contains(f) && i < all.length) i++;
            continue;
          }
          // For `timeout 5 vim`: a numeric argument with optional unit.
          if (wrapName == 'timeout' &&
              RegExp(r'^\d+(\.\d+)?[smhd]?$').hasMatch(f)) {
            i++;
            continue;
          }
          break;
        }
        continue;
      }
      break;
    }

    if (i >= all.length) return (name: null, args: const []);

    var first = all[i];
    // Strip surrounding quotes ONLY when there's actual content between
    // them.  A bare `"` line (closing quote of a heredoc-style python -c
    // body) has length 1, so `startsWith` and `endsWith` are both true
    // for the SAME character and `substring(1, 0)` would crash with a
    // `RangeError: Only valid value is 1: 0`.
    if (first.length >= 2 &&
        ((first.startsWith('"') && first.endsWith('"')) ||
            (first.startsWith("'") && first.endsWith("'")))) {
      first = first.substring(1, first.length - 1);
    }
    first = _basename(first);
    return (
      name: first.toLowerCase(),
      args: all.skip(i + 1).toList(),
    );
  }

  /// Wrapper command names → set of short / long flags that consume the
  /// NEXT argument as a value.  Without this, `sudo -u alice vim` would
  /// be parsed as `alice` (skipped flag, then took `alice` as the
  /// program) and we'd miss blocking `vim`.
  ///
  /// We only enumerate the most common value-taking flags — anything we
  /// miss falls through to the "anything starting with `-` is a flag"
  /// loop, which is wrong but at worst over-skips one token.  The user
  /// can always fix it by using `sudo -- vim` (the `--` end-of-options
  /// marker IS handled correctly).
  static const _wrapperValueFlags = <String, Set<String>>{
    'sudo': {
      '-u', '-g', '-h', '-p', '-r', '-t', '-T', '-U', '-C', '-D',
      '--user', '--group', '--host', '--prompt', '--role', '--type',
      '--command-timeout', '--other-user', '--close-from', '--chdir',
    },
    'doas': {'-u', '-C'},
    'env': {'-u', '-C', '-S', '--unset', '--chdir', '--split-string'},
    'command': <String>{},
    'exec': {'-a'},
    'nohup': <String>{},
    'stdbuf': {'-i', '-o', '-e', '--input', '--output', '--error'},
    'time': {'-f', '-o', '--format', '--output'},
    'timeout': {'-s', '-k', '--signal', '--kill-after'},
    'nice': {'-n', '--adjustment'},
    'ionice': {'-c', '-n', '-p', '-P', '-u',
               '--class', '--classdata', '--pid', '--pgid', '--uid'},
  };

  static String _basename(String tok) {
    final slash = tok.lastIndexOf('/');
    return slash >= 0 ? tok.substring(slash + 1) : tok;
  }

  // ── REPL classification ─────────────────────────────────────────────

  // Flags that turn a REPL invocation into a non-interactive one-shot:
  //   • `-c "<code>"`   (python, node)
  //   • `-e "<code>"`   (node, ruby)
  //   • `-m <module>`   (python: run a stdlib module)
  //   • `-p "<expr>"`   (node: print the value)
  //   • `--command=…`/`--eval=…`/`--print=…` (long forms)
  // Plus info-only flags that print-and-exit (`--version`, `-V`, `-v`, `-h`,
  // `--help`).  Any of these → not a REPL.  Anything else that *starts*
  // with `-` is just a tuning knob (`-B`, `-u`, `-OO`, `--no-warnings`) and
  // does NOT save us from the REPL — so it must NOT short-circuit the
  // check to "non-interactive".
  //
  // We deliberately keep this list short instead of trying to encode every
  // language's exact flag set: any unknown flag falls through to the
  // positional-arg check below, which is enough for the common cases.
  static const _replExecuteFlags = {
    '-c', '-e', '-m', '-p',
    '--command', '--eval', '--print',
  };
  static const _replExecutePrefixes = [
    '--command=', '--eval=', '--print=',
  ];
  static const _replInfoFlags = {
    '-V', '-v', '-h',
    '--version', '--help',
  };

  static bool _replIsInteractive(List<String> args) {
    if (args.isEmpty) return true;
    // Force-interactive flags ALWAYS win, even alongside a script path
    // (`python3 -i script.py` runs the script then drops into the REPL).
    for (final a in args) {
      if (a == '-i' || a == '--interactive') return true;
      // Clustered short flags whose first letter is `i` (`-il` etc.) —
      // ruby honours these; python/node ignore them but a false-positive
      // block is far safer than a false-negative hang.
      if (RegExp(r'^-i[A-Za-z]+$').hasMatch(a)) return true;
    }
    // From here we're looking for a positive signal that this is a ONE-SHOT
    // invocation (will exit on its own).  Iterate the tokens; if NOTHING
    // matches, default back to "interactive" so the REPL is blocked.
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (_replExecuteFlags.contains(a)) return false;
      if (_replInfoFlags.contains(a)) return false;
      if (_replExecutePrefixes.any(a.startsWith)) return false;
      // Positional (non-flag) token — a script path / module name / one-off
      // expression that the REPL will execute and exit.
      if (!a.startsWith('-')) return false;
    }
    return true;
  }

  // ── DB CLI classification ───────────────────────────────────────────

  static bool _dbCliIsInteractive(String name, List<String> args) {
    if (args.isEmpty) return true;
    switch (name) {
      case 'mysql':
        // `mysql -e "..."`, `mysql --execute=...`, `mysql --version`,
        // `mysql --help`.  Plain `mysql dbname` is still interactive.
        return !_hasAnyFlag(args, [
              '-e',
              '--execute',
              '-V',
              '--version',
              '--help',
              '-?',
            ]) &&
            !_hasFlagPrefix(args, '--execute=');
      case 'psql':
        // `-c`, `--command`, `-f`, `--file`, `-l`, `--list`, `--version`.
        return !_hasAnyFlag(args, [
              '-c',
              '--command',
              '-f',
              '--file',
              '-l',
              '--list',
              '-V',
              '--version',
              '--help',
            ]) &&
            !_hasFlagPrefix(args, '--command=') &&
            !_hasFlagPrefix(args, '--file=');
      case 'redis-cli':
        // Any positional non-flag token after option flags = command mode
        // (e.g. `redis-cli ping`, `redis-cli -h host -p 6379 keys *`).
        return !_hasPositional(args, _redisCliFlagsTakingValue) &&
            !_hasAnyFlag(args, ['--version', '-v', '--help']);
      case 'mongo':
      case 'mongosh':
        return !_hasAnyFlag(args, [
              '--eval',
              '-f',
              '--file',
              '--version',
              '--help',
            ]) &&
            !_hasFlagPrefix(args, '--eval=') &&
            !_hasFlagPrefix(args, '--file=');
      case 'sqlite3':
        // sqlite3 has no `-e`; you pass SQL as a positional after the DB
        // path: `sqlite3 db.sqlite "SELECT 1"`.  `-cmd "<dotcmd>"` also
        // runs and exits.  `sqlite3 :memory: "SELECT 1"` works too.
        return _countPositionals(args, _sqlite3FlagsTakingValue) < 2 &&
            !_hasAnyFlag(args, ['-cmd', '--version', '-version', '-help']);
    }
    return true;
  }

  static String _dbCliExampleHint(String name) {
    switch (name) {
      case 'mysql':
        return 'Use `mysql -e "SELECT 1"` to run a single statement.';
      case 'psql':
        return 'Use `psql -c "SELECT 1"` or `psql -f script.sql`.';
      case 'redis-cli':
        return 'Pass the Redis command as arguments, e.g. `redis-cli ping`.';
      case 'mongo':
      case 'mongosh':
        return 'Use `$name --eval "db.runCommand({ping:1})"` or `--file script.js`.';
      case 'sqlite3':
        return 'Use `sqlite3 db.sqlite "SELECT 1"` to run a one-shot query.';
    }
    return '';
  }

  // ── Token / flag helpers ────────────────────────────────────────────

  /// Flags of `redis-cli` that consume the NEXT argument as a value.
  /// Without this list we'd misclassify `redis-cli -h myhost ping` as
  /// `myhost` being a positional, which it isn't.
  static const _redisCliFlagsTakingValue = {
    '-h', '-p', '-s', '-a', '-u', '-n', '-r', '-i', '-x', '--user', '--pass',
    '--cert', '--key', '--cacert', '--cacertdir', '--tls-ciphers',
    '--tls-ciphersuites', '--sni',
  };

  /// Flags of `sqlite3` that consume the next arg.  `-init <file>`,
  /// `-cmd <cmd>` (treated separately as execute), `-separator <sep>`, …
  static const _sqlite3FlagsTakingValue = {
    '-init', '-separator', '-newline', '-nullvalue', '-pagecache',
    '-lookaside',
  };

  static bool _hasAnyFlag(List<String> args, List<String> flags) {
    for (final a in args) {
      if (flags.contains(a)) return true;
    }
    return false;
  }

  static bool _hasFlagPrefix(List<String> args, String prefix) {
    for (final a in args) {
      if (a.startsWith(prefix)) return true;
    }
    return false;
  }

  /// `true` iff [args] contains a non-flag positional after skipping
  /// recognised flag/value pairs.
  static bool _hasPositional(List<String> args, Set<String> flagsTakingValue) {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.startsWith('-')) {
        if (flagsTakingValue.contains(a)) i++; // skip its value
        continue;
      }
      return true;
    }
    return false;
  }

  static int _countPositionals(
    List<String> args,
    Set<String> flagsTakingValue,
  ) {
    var n = 0;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.startsWith('-')) {
        if (flagsTakingValue.contains(a)) i++;
        continue;
      }
      n++;
    }
    return n;
  }

  /// Minimal POSIX-ish tokeniser: respects single + double quotes (no
  /// escape processing inside quotes, which is enough for our heuristics).
  /// `python3 -c "print(1)"` → `[python3, -c, "print(1)"]`.
  static List<String> _tokenise(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        buf.write(c);
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        buf.write(c);
        continue;
      }
      if (c == ' ' || c == '\t') {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        continue;
      }
      buf.write(c);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }
}
