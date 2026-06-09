import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/command_safety.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('CommandSafety.parseInvocation', () {
    test('plain command', () {
      final inv = CommandSafety.parseInvocation('ls -la');
      expect(inv.name, equals('ls'));
      expect(inv.args, equals(['-la']));
    });

    test('absolute-path program → basename', () {
      final inv = CommandSafety.parseInvocation('/usr/bin/python3 -c "x"');
      expect(inv.name, equals('python3'));
      expect(inv.args, equals(['-c', '"x"']));
    });

    test('strips `sudo` wrapper', () {
      final inv = CommandSafety.parseInvocation('sudo vim /etc/hosts');
      expect(inv.name, equals('vim'));
      expect(inv.args, equals(['/etc/hosts']));
    });

    test('strips `sudo -u alice` wrapper with flags', () {
      final inv = CommandSafety.parseInvocation('sudo -u alice -- htop');
      expect(inv.name, equals('htop'));
    });

    test('strips `env VAR=val` and assignments', () {
      final inv =
          CommandSafety.parseInvocation('env FOO=bar BAZ=qux python3 -V');
      expect(inv.name, equals('python3'));
      expect(inv.args, equals(['-V']));
    });

    test('strips `timeout 5s` numeric argument', () {
      final inv = CommandSafety.parseInvocation('timeout 5s top');
      expect(inv.name, equals('top'));
    });

    test('strips `nohup`', () {
      final inv = CommandSafety.parseInvocation('nohup top &');
      expect(inv.name, equals('top'));
    });

    test('returns null for empty / whitespace input', () {
      expect(CommandSafety.parseInvocation('').name, isNull);
      expect(CommandSafety.parseInvocation('   ').name, isNull);
    });

    test('respects double-quoted args (no token split inside quotes)', () {
      final inv =
          CommandSafety.parseInvocation('python3 -c "print(1 + 2)"');
      expect(inv.name, equals('python3'));
      expect(inv.args, equals(['-c', '"print(1 + 2)"']));
    });

    test('respects single-quoted args', () {
      final inv = CommandSafety.parseInvocation("mysql -e 'SELECT 1, 2'");
      expect(inv.name, equals('mysql'));
      expect(inv.args, equals(['-e', "'SELECT 1, 2'"]));
    });

    test('does NOT crash on a bare single quote (REGRESSION: substring 1,0)',
        () {
      // Hit in production: multi-line `python3 -c "..."` whose closing
      // line is just `"` — `parseInvocation` was called on that line and
      // crashed at substring(1, length-1) when length == 1.
      expect(() => CommandSafety.parseInvocation('"'), returnsNormally);
      expect(() => CommandSafety.parseInvocation("'"), returnsNormally);
      // The bare quote is NOT a recognised program, so `name` should be
      // `"` (preserved verbatim).  The important assertion is no throw.
      expect(CommandSafety.parseInvocation('"').name, equals('"'));
    });

    test('handles a bare unmatched-quote token without crashing', () {
      // `mysql -e "SELECT` is the START of a quoted region whose closer
      // landed on a different line.  The tokeniser leaves the quote open,
      // accumulating everything into one token.  Either way: no crash.
      expect(() => CommandSafety.parseInvocation('mysql -e "SELECT'),
          returnsNormally);
    });
  });

  group('CommandSafety.reason — happy path (allowed)', () {
    void allow(String cmd) {
      final r = CommandSafety.reason(cmd);
      expect(r, isNull,
          reason: '$cmd should be allowed but was blocked: "$r"');
    }

    test('plain shell commands', () {
      allow('ls -la');
      allow('cat /etc/hosts');
      allow('grep -r "TODO" .');
      allow('echo "hello world"');
    });

    test('python3 with -c is allowed (REGRESSION — was blocked)', () {
      allow('python3 -c "print(1)"');
      allow('python -c "import sys; print(sys.version)"');
    });

    test('python3 with a script path is allowed', () {
      allow('python3 script.py');
      allow('python3 ./tests/foo.py --verbose');
      allow('/usr/bin/python3 /tmp/setup.py install');
    });

    test('python3 -m module is allowed', () {
      allow('python3 -m site');
      allow('python3 -m pip install requests');
      allow('python3 -m http.server 8000');
    });

    test('python --version / --help', () {
      allow('python3 --version');
      allow('python -V');
    });

    test('node with script / -e is allowed', () {
      allow('node app.js');
      allow('node -e "console.log(1+1)"');
      allow('node --version');
    });

    test('mysql -e is allowed', () {
      allow('mysql -e "SELECT 1"');
      allow('mysql --execute="SELECT 1"');
      allow('mysql -h localhost -u root -e "SHOW DATABASES"');
    });

    test('psql -c / -f is allowed', () {
      allow('psql -c "SELECT 1"');
      allow('psql --command="SELECT 1"');
      allow('psql -f script.sql');
      allow('psql -l');
    });

    test('redis-cli with a positional command is allowed', () {
      allow('redis-cli ping');
      allow('redis-cli -h localhost -p 6379 keys "*"');
      allow('redis-cli get mykey');
    });

    test('mongosh --eval is allowed', () {
      allow('mongosh --eval "db.runCommand({ping:1})"');
      allow('mongosh --eval="db.version()"');
    });

    test('sqlite3 with positional SQL is allowed', () {
      allow('sqlite3 db.sqlite "SELECT 1"');
      allow('sqlite3 :memory: "SELECT sqlite_version()"');
      allow('sqlite3 -version');
    });

    test('logical AND `&&` is NOT a background `&`', () {
      allow('mkdir -p /tmp/foo && cd /tmp/foo');
      allow('ls && echo done');
    });

    test('escaped `\\&` is not treated as background', () {
      allow(r'echo "a \& b"');
    });

    test('`tail` without -f is allowed', () {
      allow('tail -n 100 /var/log/messages');
    });
  });

  group('CommandSafety.reason — always-interactive blocks', () {
    void block(String cmd, {String? expectedSubstring}) {
      final r = CommandSafety.reason(cmd);
      expect(r, isNotNull, reason: '$cmd should be blocked');
      if (expectedSubstring != null) {
        expect(r, contains(expectedSubstring),
            reason: 'Reason "$r" should mention $expectedSubstring');
      }
    }

    test('vim / nano / emacs', () {
      block('vim /etc/hosts', expectedSubstring: 'interactive');
      block('nano README.md');
      block('emacs');
    });

    test('less / more / man', () {
      block('less /var/log/messages');
      block('more /etc/passwd');
      block('man ls');
    });

    test('top / htop', () {
      block('top');
      block('htop');
    });

    test('absolute-path vim is also blocked', () {
      block('/usr/bin/vim foo.txt');
    });

    test('sudo-wrapped vim is blocked', () {
      block('sudo vim /etc/hosts');
    });
  });

  group('CommandSafety.reason — REPL blocks', () {
    void block(String cmd) {
      expect(CommandSafety.reason(cmd), isNotNull,
          reason: '$cmd should be blocked');
    }

    test('bare python / python3 / node', () {
      block('python');
      block('python3');
      block('node');
    });

    test('python3 -i is force-interactive even with a script', () {
      block('python3 -i');
      block('python3 -i script.py');
    });

    test('node --interactive is force-interactive', () {
      block('node --interactive');
    });

    test('sudo-wrapped bare python is blocked', () {
      block('sudo python3');
    });

    test('python tuning flags WITHOUT a script still drop into REPL '
        '(REGRESSION — used to slip through _replIsInteractive)', () {
      // Pre-fix behaviour: `_replIsInteractive` only blocked args
      // containing `-i`; ANY other flag was taken as "non-interactive"
      // and the user got a 120-second deadlock as python sat at `>>>`.
      block('python3 -B');
      block('python3 -u');
      block('python3 -OO');
      block('python3 -B -u -OO');
      block('python -O');
      // Long flags without an execute form are still REPLs.
      block('python3 --no-warnings');
    });

    test('node tuning flags WITHOUT a script are blocked', () {
      block('node --no-warnings');
      block('node --experimental-vm-modules');
    });

    test('python3 -i script.py is blocked even with a script path', () {
      // `-i` makes python drop into the REPL *after* the script runs.
      // Must stay blocked even though there's also a positional arg.
      block('python3 -i script.py');
      block('python3 -i -B script.py');
    });
  });

  group('CommandSafety.reason — REPL allow-list', () {
    void allow(String cmd) {
      final r = CommandSafety.reason(cmd);
      expect(r, isNull,
          reason: '$cmd should be allowed but was blocked: "$r"');
    }

    test('node -p / --print is non-interactive', () {
      allow('node -p "process.version"');
      allow('node --print "process.platform"');
    });

    test('--eval=expr / --command=stmt long forms are non-interactive', () {
      // `node --eval="..."` and `psql --command="..."` both use the
      // joined `=value` long-form.  Without _replExecutePrefixes these
      // looked like opaque flags to the REPL checker.
      allow('node --eval="1+1"');
    });

    test('python -c (clustered with quotes) is non-interactive', () {
      allow('python3 -c "import os; print(os.getcwd())"');
    });
  });

  group('CommandSafety.reason — DB CLI blocks', () {
    void block(String cmd, {String? hint}) {
      final r = CommandSafety.reason(cmd);
      expect(r, isNotNull, reason: '$cmd should be blocked');
      if (hint != null) {
        expect(r, contains(hint));
      }
    }

    test('plain mysql', () {
      block('mysql', hint: 'mysql -e');
      block('mysql -h localhost -u root');
      block('mysql mydb');
    });

    test('plain psql', () {
      block('psql', hint: 'psql -c');
      block('psql -h localhost mydb');
    });

    test('plain redis-cli (no positional)', () {
      // Just `redis-cli` or with only flag/value pairs — no command — is REPL.
      block('redis-cli');
      block('redis-cli -h localhost -p 6379');
    });

    test('plain mongosh', () {
      block('mongosh');
      block('mongosh mongodb://localhost/mydb');
    });

    test('plain sqlite3 (just the DB file)', () {
      // One positional = DB file only, drops into REPL.
      block('sqlite3 db.sqlite');
    });
  });

  group('CommandSafety.reason — background `&`', () {
    test('trailing `&` is blocked', () {
      final r = CommandSafety.reason('ls > /tmp/out &');
      expect(r, isNotNull);
      expect(r, contains('Background'));
    });

    test('per-line check: background on first of two lines is caught', () {
      final r = CommandSafety.reason('long-job > out &\necho done');
      expect(r, isNotNull);
      expect(r, contains('Background'));
    });
  });

  group('CommandSafety.reason — tail -f / watch', () {
    test('tail -f blocked', () {
      final r = CommandSafety.reason('tail -f /var/log/messages');
      expect(r, isNotNull);
      expect(r, contains('tail -f'));
    });

    test('tail --follow blocked', () {
      final r = CommandSafety.reason('tail --follow=name /var/log/foo');
      expect(r, isNotNull);
    });

    test('watch blocked', () {
      final r = CommandSafety.reason('watch -n 1 ls');
      expect(r, isNotNull);
      expect(r, contains('watch'));
    });
  });

  group('CommandSafety.reason — multi-line scans', () {
    test('blocks on a hidden interactive command in line 2', () {
      final r = CommandSafety.reason('echo hello\nvim /etc/hosts');
      expect(r, isNotNull);
      expect(r, contains('vim'));
    });

    test('allows a clean multi-line script', () {
      final r = CommandSafety.reason('echo hello\necho world\nls -la');
      expect(r, isNull);
    });

    test(
        'multi-line python3 -c "…" heredoc does NOT crash (REGRESSION)',
        () {
      // In production the LLM emitted a multi-line `python3 -c "…"`
      // whose closing `"` was on its own line.  Per-line parsing tried
      // to extract a program name from the bare `"` line and crashed
      // with `RangeError: Only valid value is 1: 0` from substring(1, 0).
      // After the fix, the whole multi-line command should be allowed.
      const script = '''python3 -c "
def sieve(n):
    s = [True] * (n+1)
    s[0:2] = [False, False]
    for i in range(2, int(n**0.5)+1):
        if s[i]:
            for j in range(i*i, n+1, i):
                s[j] = False
    return [i for i, p in enumerate(s) if p]
print(sieve(100)[-1])
"''';
      expect(() => CommandSafety.reason(script), returnsNormally);
      expect(CommandSafety.reason(script), isNull,
          reason: 'python3 -c "…" should be allowed');
    });
  });

  group('CommandSafety.altScreenReason', () {
    // Pin the LLM-facing wording.  The actual `term.isUsingAltBuffer`
    // gate lives in `_executeAndCapture` (private to main_ssh.dart);
    // this group exercises the two halves the gate composes:
    //
    //   1. The const message exists and contains the user-recovery
    //      hints the LLM is supposed to relay verbatim.
    //   2. xterm's `Terminal.isUsingAltBuffer` actually flips on the
    //      escape sequences a real TUI emits — proving our chosen
    //      detection signal works end-to-end without spinning up a
    //      Tab/Session harness.
    //
    // Together these guarantee that a refactor of either side (a
    // rewording of the envelope OR an xterm upgrade that changes the
    // alt-buffer trigger) breaks a test before it ships.
    test('message names common TUIs and gives concrete escape hatches', () {
      final r = CommandSafety.altScreenReason;
      expect(r, contains('alternate-screen'));
      expect(r, contains('vim'));
      expect(r, contains('less'));
      expect(r, contains('tmux'));
      // Recovery hints the model should pass to the user.
      expect(r, contains(':q'));
      expect(r, contains('Ctrl-B d'));
      // Loop-control directive: prevent retry storms while user is
      // still inside the TUI.
      expect(r, contains('Do NOT retry'));
    });

    test('xterm Terminal.isUsingAltBuffer flips on CSI ?1049h / ?1049l', () {
      // The detection signal we depend on.  If a future xterm upgrade
      // ever changes this, the agent's alt-screen guard would silently
      // stop firing and the user would be back to "agent typed `ls`
      // into my vim buffer" — this test makes that regression loud.
      final terminal = Terminal();
      expect(terminal.isUsingAltBuffer, isFalse,
          reason: 'fresh terminal must start on the main buffer');

      terminal.write('\x1b[?1049h');
      expect(terminal.isUsingAltBuffer, isTrue,
          reason: 'CSI ?1049h must enter the alt buffer');

      terminal.write('\x1b[?1049l');
      expect(terminal.isUsingAltBuffer, isFalse,
          reason: 'CSI ?1049l must restore the main buffer');
    });

    test('xterm Terminal.isUsingAltBuffer also flips on legacy CSI ?1047h', () {
      // Older TUIs (and `less` on some platforms) still emit the
      // pre-xterm-251 `?1047` toggle.  Cover it explicitly so dropping
      // support in xterm would be caught here too.
      final terminal = Terminal();
      terminal.write('\x1b[?1047h');
      expect(terminal.isUsingAltBuffer, isTrue);
      terminal.write('\x1b[?1047l');
      expect(terminal.isUsingAltBuffer, isFalse);
    });
  });
}
