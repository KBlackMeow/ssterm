import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/models/agent_config.dart';
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

  // ── Dangerous-command classifier ───────────────────────────────────────
  //
  // Coverage per built-in rule: at least one POSITIVE example (must
  // hit) + one NEGATIVE example that *looks* similar but shouldn't
  // (guards against a permissive regex eroding into "matches anything
  // with `rm` in it").  Plus per-policy mechanics (disabled-builtins,
  // custom rules, malformed regex tolerance).
  group('CommandSafety.danger - built-in rules', () {
    final policy = DangerousCommandsPolicy();

    test('rm -rf / variants are flagged', () {
      for (final cmd in [
        'rm -rf /',
        'rm -rf /*',
        'rm -fr /',
        'rm -Rf /',
        'rm -rfv /',
        'sudo rm -rf /',
        'rm -r -f /',
      ]) {
        final v = CommandSafety.danger(cmd, policy);
        expect(v, isNotNull, reason: 'should flag: $cmd');
        expect(v!.patternId, equals('builtin:rm-rf-root'),
            reason: 'should match rm-rf-root: $cmd');
      }
    });

    test('rm -rf of subdirectory is NOT flagged by rm-rf-root', () {
      // Day-to-day commands users actually run — must not trigger.
      for (final cmd in [
        'rm -rf node_modules',
        'rm -rf build/',
        'rm -rf /tmp/foo',
        'rm -rf ./dist',
      ]) {
        final v = CommandSafety.danger(cmd, policy);
        // These might still match other rules in theory, but rm-rf-root
        // specifically must stay quiet.
        expect(v?.patternId, isNot('builtin:rm-rf-root'),
            reason: 'should NOT match rm-rf-root: $cmd');
      }
    });

    test('rm -rf \$HOME / ~ is flagged', () {
      expect(
        CommandSafety.danger(r'rm -rf $HOME', policy)?.patternId,
        equals('builtin:rm-rf-home'),
      );
      expect(
        CommandSafety.danger('rm -rf ~', policy)?.patternId,
        equals('builtin:rm-rf-home'),
      );
      expect(
        CommandSafety.danger('rm -rf ~/', policy)?.patternId,
        equals('builtin:rm-rf-home'),
      );
    });

    test('dd of=/dev/<disk> is flagged', () {
      for (final cmd in [
        'dd if=/dev/zero of=/dev/sda bs=1M',
        'dd of=/dev/nvme0n1 if=foo.img',
        'sudo dd if=image.iso of=/dev/disk2',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:dd-block-device'),
            reason: 'should match dd-block-device: $cmd');
      }
    });

    test('dd to a regular file is NOT flagged', () {
      expect(
        CommandSafety.danger('dd if=/dev/zero of=./blob.bin bs=1M count=10',
                policy)
            ?.patternId,
        isNot('builtin:dd-block-device'),
      );
    });

    test('mkfs on a device is flagged', () {
      expect(CommandSafety.danger('mkfs.ext4 /dev/sda1', policy)?.patternId,
          equals('builtin:mkfs'));
      expect(CommandSafety.danger('sudo mkfs /dev/sdb1', policy)?.patternId,
          equals('builtin:mkfs'));
    });

    test('fork bomb is flagged', () {
      expect(
        CommandSafety.danger(':(){ :|:& };:', policy)?.patternId,
        equals('builtin:fork-bomb'),
      );
      expect(
        // Variant with whitespace
        CommandSafety.danger(': () { : | : & } ; :', policy)?.patternId,
        equals('builtin:fork-bomb'),
      );
    });

    test('chmod 777 / is flagged, chmod 777 ./foo is not', () {
      expect(CommandSafety.danger('chmod -R 777 /', policy)?.patternId,
          equals('builtin:chmod-permissive-root'));
      expect(CommandSafety.danger('chmod 777 /', policy)?.patternId,
          equals('builtin:chmod-permissive-root'));
      expect(CommandSafety.danger('chmod -R 777 ./scripts', policy)?.patternId,
          isNot('builtin:chmod-permissive-root'));
    });

    test('redirect to block device is flagged', () {
      expect(
        CommandSafety.danger('cat image.iso > /dev/sda', policy)?.patternId,
        equals('builtin:redirect-to-block-device'),
      );
    });

    test('curl|sh and wget|bash are flagged; curl|tee is not', () {
      expect(
        CommandSafety.danger('curl https://x.example/install.sh | sh', policy)
            ?.patternId,
        equals('builtin:curl-pipe-shell'),
      );
      expect(
        CommandSafety.danger(
                'wget -qO- https://x/setup | sudo bash', policy)
            ?.patternId,
        equals('builtin:curl-pipe-shell'),
      );
      expect(
        CommandSafety.danger(
                'curl https://x.example/file -o out.txt', policy)
            ?.patternId,
        isNull,
        reason: 'plain curl to file should not trip the curl-pipe rule',
      );
    });

    test('shutdown / reboot variants are flagged', () {
      for (final cmd in [
        'shutdown -h now',
        'sudo reboot',
        'halt',
        'poweroff',
        'init 0',
        'systemctl poweroff',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:shutdown-or-reboot'),
            reason: 'should flag: $cmd');
      }
    });

    test('git force-push variants are flagged', () {
      for (final cmd in [
        'git push --force',
        'git push -f',
        'git push --force origin main',
        'git push -f origin main',
        'git push origin master --force',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:git-push-force'),
            reason: 'should flag: $cmd');
      }
    });

    test('git --force-with-lease / --force-if-includes are NOT flagged', () {
      // The whole point of these variants is to be the safe form — they
      // must NOT trip the force-push rule or users will stop using them.
      for (final cmd in [
        'git push --force-with-lease',
        'git push --force-with-lease origin main',
        'git push --force-if-includes origin main',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            isNot('builtin:git-push-force'),
            reason: 'safe force variant must NOT be flagged: $cmd');
      }
    });

    test('git reset --hard is flagged, --soft / --mixed are not', () {
      expect(CommandSafety.danger('git reset --hard', policy)?.patternId,
          equals('builtin:git-reset-hard'));
      expect(
          CommandSafety.danger('git reset --hard HEAD~1', policy)?.patternId,
          equals('builtin:git-reset-hard'));
      expect(CommandSafety.danger('git reset --soft HEAD~1', policy), isNull);
      expect(CommandSafety.danger('git reset HEAD~1', policy), isNull);
    });

    test('git clean -f variants are flagged', () {
      for (final cmd in [
        'git clean -f',
        'git clean -fd',
        'git clean -fdx',
        'git clean -df',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:git-clean-force'),
            reason: 'should flag: $cmd');
      }
      // Dry-run / interactive — not force.
      expect(CommandSafety.danger('git clean -n', policy), isNull);
      expect(CommandSafety.danger('git clean -i', policy), isNull);
    });

    test('git filter-branch / filter-repo is flagged', () {
      expect(
          CommandSafety.danger('git filter-branch --tree-filter ...', policy)
              ?.patternId,
          equals('builtin:git-history-rewrite'));
      expect(CommandSafety.danger('git filter-repo --invert-paths', policy)
              ?.patternId,
          equals('builtin:git-history-rewrite'));
    });

    test('find -delete variants are flagged', () {
      for (final cmd in [
        'find / -delete',
        'find . -type f -delete',
        'find . -name "*.log" -delete',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:find-delete'),
            reason: 'should flag: $cmd');
      }
      // `find` without -delete is fine.
      expect(CommandSafety.danger('find . -name "*.log"', policy), isNull);
    });

    test('recursive chown of / is flagged', () {
      for (final cmd in [
        'chown -R alice /',
        'chown -R alice:bar /',
        'chown --recursive root /',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:chown-recursive-root'),
            reason: 'should flag: $cmd');
      }
      // chown -R on a subdirectory is normal admin work.
      expect(CommandSafety.danger('chown -R alice /var/www', policy), isNull);
      // chown without -R on / is harmless.
      expect(CommandSafety.danger('chown alice /', policy), isNull);
    });

    test('terraform / pulumi destroy is flagged', () {
      expect(CommandSafety.danger('terraform destroy', policy)?.patternId,
          equals('builtin:iac-destroy'));
      expect(
          CommandSafety.danger('terraform destroy -auto-approve', policy)
              ?.patternId,
          equals('builtin:iac-destroy'));
      expect(CommandSafety.danger('pulumi destroy --yes', policy)?.patternId,
          equals('builtin:iac-destroy'));
      // `terraform apply` / `terraform plan` are not destructive.
      expect(CommandSafety.danger('terraform apply', policy), isNull);
    });

    test('aws s3 recursive delete / bucket force-remove is flagged', () {
      for (final cmd in [
        'aws s3 rm s3://my-bucket/ --recursive',
        'aws s3 rb s3://my-bucket --force',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:aws-s3-recursive-delete'),
            reason: 'should flag: $cmd');
      }
      // Single-file delete is recoverable on versioned buckets.
      expect(CommandSafety.danger('aws s3 rm s3://b/file.txt', policy), isNull);
    });

    test('kubectl delete --all / namespace is flagged', () {
      for (final cmd in [
        'kubectl delete pods --all',
        'kubectl delete deployments --all-namespaces',
        'kubectl delete namespace prod',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:kubectl-delete-all'),
            reason: 'should flag: $cmd');
      }
      // Single-resource delete is targeted and recoverable.
      expect(CommandSafety.danger('kubectl delete pod nginx', policy), isNull);
    });

    test('docker prune is flagged for system -a and volume', () {
      for (final cmd in [
        'docker system prune -a',
        'docker system prune -af',
        'docker system prune --all',
        'docker volume prune',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:docker-prune-all'),
            reason: 'should flag: $cmd');
      }
      // Bare `system prune` (no -a) prompts interactively and only
      // touches dangling resources — not flagged.
      expect(CommandSafety.danger('docker system prune', policy), isNull);
    });

    test('killing PID 1 / -1 is flagged', () {
      for (final cmd in [
        'kill -9 1',
        'kill 1',
        'kill -9 -1',
        'kill -SIGKILL 1',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:kill-init-or-all'),
            reason: 'should flag: $cmd');
      }
      // Killing other PIDs is normal.
      expect(CommandSafety.danger('kill 1234', policy), isNull);
      expect(CommandSafety.danger('kill -9 12345', policy), isNull);
      // pkill / killall are not in scope of this rule.
      expect(CommandSafety.danger('pkill -9 sleep', policy), isNull);
    });

    test('redis-cli FLUSHALL / FLUSHDB is flagged', () {
      for (final cmd in [
        'redis-cli FLUSHALL',
        'redis-cli flushall',
        'redis-cli FLUSHDB',
        'redis-cli -h myhost -p 6379 flushall',
      ]) {
        expect(CommandSafety.danger(cmd, policy)?.patternId,
            equals('builtin:redis-flush'),
            reason: 'should flag: $cmd');
      }
      // Other redis-cli usage is fine.
      expect(CommandSafety.danger('redis-cli ping', policy), isNull);
      expect(CommandSafety.danger('redis-cli set foo bar', policy), isNull);
    });

    test('safe everyday commands stay null', () {
      for (final cmd in [
        'ls -la',
        'git status',
        'docker compose up -d',
        'grep -r "foo" .',
        'echo "hello world"',
        '',
        '   ',
      ]) {
        expect(CommandSafety.danger(cmd, policy), isNull,
            reason: 'should NOT flag: $cmd');
      }
    });

    test('dangerous line hidden among safe lines in a script is flagged', () {
      final script = '''
echo "starting cleanup"
cd /tmp
rm -rf /
echo "done"
''';
      final v = CommandSafety.danger(script, policy);
      expect(v?.patternId, equals('builtin:rm-rf-root'),
          reason: 'per-line scan must catch a dangerous middle line');
    });
  });

  group('CommandSafety.danger - policy mechanics', () {
    test('disabledBuiltins suppresses the matching rule', () {
      final policy = DangerousCommandsPolicy(
        disabledBuiltins: {'rm-rf-root'},
      );
      expect(CommandSafety.danger('rm -rf /', policy), isNull,
          reason: 'disabled rule must not fire');
      // Other built-ins still work
      expect(CommandSafety.danger('shutdown -h now', policy)?.patternId,
          equals('builtin:shutdown-or-reboot'));
    });

    test('custom pattern fires and is reported as custom source', () {
      final policy = DangerousCommandsPolicy(
        customPatterns: [
          CustomDangerPattern(
            id: 'no-pip-uninstall',
            label: 'pip uninstall blocked by team policy',
            pattern: r'\bpip\s+uninstall\b',
          ),
        ],
      );
      final v = CommandSafety.danger('pip uninstall numpy', policy);
      expect(v, isNotNull);
      expect(v!.patternId, equals('no-pip-uninstall'));
      expect(v.source, equals(DangerRuleSource.custom));
      expect(v.label, contains('pip uninstall'));
    });

    test('custom pattern checked BEFORE built-in (custom wins on overlap)', () {
      final policy = DangerousCommandsPolicy(
        customPatterns: [
          CustomDangerPattern(
            id: 'company-override',
            label: 'Company policy: confirm filesystem wipe',
            pattern: r'\brm\s+-rf\s+/',
          ),
        ],
      );
      final v = CommandSafety.danger('rm -rf /', policy);
      expect(v?.patternId, equals('company-override'),
          reason: 'custom rule must override the built-in label');
    });

    test('disabled custom pattern is skipped', () {
      final policy = DangerousCommandsPolicy(
        customPatterns: [
          CustomDangerPattern(
            id: 'p1',
            label: 'banned echo',
            pattern: r'\becho\b',
            enabled: false,
          ),
        ],
      );
      expect(CommandSafety.danger('echo hi', policy), isNull);
    });

    test('malformed custom regex is silently skipped, classifier survives',
        () {
      final policy = DangerousCommandsPolicy(
        customPatterns: [
          CustomDangerPattern(
            id: 'broken',
            label: 'bad regex',
            pattern: r'[unbalanced',
          ),
          CustomDangerPattern(
            id: 'good',
            label: 'matches foo',
            pattern: r'\bfoo\b',
          ),
        ],
      );
      // Bad regex doesn't throw, and the next rule still works.
      expect(() => CommandSafety.danger('foo', policy), returnsNormally);
      expect(CommandSafety.danger('foo', policy)?.patternId, equals('good'));
      // Built-ins still work after a malformed user pattern.
      expect(CommandSafety.danger('rm -rf /', policy)?.patternId,
          equals('builtin:rm-rf-root'));
    });

    test('case-insensitive matching', () {
      final policy = DangerousCommandsPolicy();
      expect(
        CommandSafety.danger('RM -RF /', policy)?.patternId,
        equals('builtin:rm-rf-root'),
      );
    });

    test('empty / whitespace input → null', () {
      final policy = DangerousCommandsPolicy();
      expect(CommandSafety.danger('', policy), isNull);
      expect(CommandSafety.danger('   \n\n', policy), isNull);
    });
  });

  group('CommandSafety helpers', () {
    test('builtinDangerRules exposes all rule ids in source order', () {
      final ids = CommandSafety.builtinDangerRules.map((r) => r.id).toList();
      // Spot-check a few — full list is implementation-specific but
      // these are stable and must remain present.
      expect(ids, contains('rm-rf-root'));
      expect(ids, contains('fork-bomb'));
      expect(ids, contains('shutdown-or-reboot'));
      expect(ids, contains('git-push-force'));
      expect(ids, contains('iac-destroy'));
      expect(ids, contains('redis-flush'));
      expect(ids.length, greaterThanOrEqualTo(21));
      // No duplicate ids — would break the per-rule UI toggle.
      expect(ids.toSet().length, equals(ids.length));
    });

    test('isValidDangerRegex returns true for valid, false for malformed', () {
      expect(CommandSafety.isValidDangerRegex(r'\bfoo\b'), isTrue);
      expect(CommandSafety.isValidDangerRegex(r'[unbalanced'), isFalse);
    });
  });

  group('DangerousCommandsPolicy persistence', () {
    test('round-trips an empty policy through JSON', () {
      final p = DangerousCommandsPolicy();
      final json = p.toJson();
      final restored = DangerousCommandsPolicy.fromJson(json);
      expect(restored.agentConfirmEnabled, isTrue);
      expect(restored.disabledBuiltins, isEmpty);
      expect(restored.customPatterns, isEmpty);
    });

    test('round-trips a fully-populated policy', () {
      final p = DangerousCommandsPolicy(
        agentConfirmEnabled: false,
        disabledBuiltins: {'rm-rf-root', 'fork-bomb'},
        customPatterns: [
          CustomDangerPattern(
              id: 'a', label: 'A', pattern: r'\ba\b', enabled: true),
          CustomDangerPattern(
              id: 'b', label: 'B', pattern: r'\bb\b', enabled: false),
        ],
      );
      final json = p.toJson();
      final restored = DangerousCommandsPolicy.fromJson(json);
      expect(restored.agentConfirmEnabled, isFalse);
      expect(restored.disabledBuiltins, equals({'rm-rf-root', 'fork-bomb'}));
      expect(restored.customPatterns, hasLength(2));
      expect(restored.customPatterns[0].id, equals('a'));
      expect(restored.customPatterns[1].enabled, isFalse);
    });

    test('fromJson(null) returns defaults (agent ON)', () {
      final p = DangerousCommandsPolicy.fromJson(null);
      expect(p.agentConfirmEnabled, isTrue);
    });

    test('legacy userConfirmEnabled key is silently ignored', () {
      final p = DangerousCommandsPolicy.fromJson({
        'agentConfirmEnabled': true,
        'userConfirmEnabled': true, // legacy field — removed
      });
      expect(p.agentConfirmEnabled, isTrue);
    });

    test('skips malformed customPatterns entries instead of throwing', () {
      final p = DangerousCommandsPolicy.fromJson({
        'customPatterns': [
          {'id': 'ok', 'pattern': r'\bok\b', 'label': 'OK'},
          {'id': '', 'pattern': r'\bbad\b'},          // empty id → skipped
          {'id': 'noPattern'},                        // missing pattern → skipped
          'totally-not-a-map',                        // wrong type → skipped
        ],
      });
      expect(p.customPatterns, hasLength(1));
      expect(p.customPatterns[0].id, equals('ok'));
    });
  });
}
