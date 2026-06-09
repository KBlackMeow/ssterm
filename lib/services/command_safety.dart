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
