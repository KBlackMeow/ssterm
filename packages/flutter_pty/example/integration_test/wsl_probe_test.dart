import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _wrapperScript = r'''
shell="${SHELL:-/bin/sh}"
shell_name="${shell##*/}"

case "$shell_name" in
  zsh)
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ssterm-zsh.XXXXXX")"
    cat >"$tmpdir/.zshenv" <<'EOF'
if [ -f "$HOME/.zshenv" ]; then
  . "$HOME/.zshenv"
fi
EOF
    cat >"$tmpdir/.zprofile" <<'EOF'
if [ -f "$HOME/.zprofile" ]; then
  . "$HOME/.zprofile"
fi
EOF
    cat >"$tmpdir/.zshrc" <<'EOF'
__ssterm_cwd() {
  printf '\033]7;file://%s\033\\' "$PWD"
}
HISTFILE="$HOME/.zsh_history"
export SSTM_SHELL_BIN=zsh
if [ -f "$HOME/.zshrc" ]; then
  . "$HOME/.zshrc"
fi
__ssterm_osc133_preexec() {
  printf '\033]133;C\007'
}
__ssterm_osc133_precmd() {
  local _ssterm_ec=$?
  printf '\033]133;D;%s\007' "$_ssterm_ec"
  return $_ssterm_ec
}
__ssterm_heal_hooks() {
  if [[ "${precmd_functions[1]}" != "__ssterm_osc133_precmd" ]]; then
    precmd_functions=(__ssterm_osc133_precmd ${precmd_functions:#__ssterm_osc133_precmd})
  fi
  case " ${precmd_functions[*]} " in
    *" __ssterm_cwd "*) : ;;
    *) precmd_functions+=(__ssterm_cwd) ;;
  esac
  case " ${preexec_functions[*]} " in
    *" __ssterm_osc133_preexec "*) : ;;
    *) preexec_functions+=(__ssterm_osc133_preexec) ;;
  esac
}
precmd_functions=(__ssterm_osc133_precmd __ssterm_heal_hooks "${precmd_functions[@]}")
__ssterm_heal_hooks
__ssterm_cwd
EOF
    cat >"$tmpdir/.zlogin" <<'EOF'
if [ -f "$HOME/.zlogin" ]; then
  . "$HOME/.zlogin"
fi
zshexit() { rm -rf "$ZDOTDIR"; }
EOF
    exec env ZDOTDIR="$tmpdir" "$shell" -i
    ;;
  bash)
    ENV=/dev/fd/3 exec "$shell" --posix --noprofile -i 3<<'RCEOF'
set +o posix
__ssterm_cwd() {
  printf '\033]7;file://%s\033\\' "$PWD"
}
export SSTM_SHELL_BIN=bash
__ssterm_osc133_preexec() {
  printf '\033]133;C\007'
}
__ssterm_osc133_precmd() {
  local _ssterm_ec=$?
  printf '\033]133;D;%s\007' "$_ssterm_ec"
  return $_ssterm_ec
}
if [ -f "$HOME/.bash_profile" ]; then
  . "$HOME/.bash_profile"
elif [ -f "$HOME/.bash_login" ]; then
  . "$HOME/.bash_login"
elif [ -f "$HOME/.profile" ]; then
  . "$HOME/.profile"
elif [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
case ";${PROMPT_COMMAND:-};" in
  *";__ssterm_cwd;"*) : ;;
  *) PROMPT_COMMAND="__ssterm_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
if [[ ${BASH_VERSINFO[0]} -gt 4 || ( ${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 4 ) ]]; then
  PS0='$(__ssterm_osc133_preexec)'
  if ! [[ "$PROMPT_COMMAND" == *__ssterm_osc133_precmd* ]]; then
    PROMPT_COMMAND="__ssterm_osc133_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
  fi
fi
__ssterm_cwd
RCEOF
    ;;
  *)
    exec "$shell" -i
    ;;
esac
''';

class _Collector {
  final Pty pty;
  final buffer = StringBuffer();
  late final StreamSubscription sub;

  _Collector(this.pty) {
    sub = pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
      buffer.write(s);
      // ignore: avoid_print
      print('CHUNK: ${s.replaceAll('\u001b', '<ESC>')}');
    });
  }

  String get output => buffer.toString();

  Future<void> waitFor(Pattern p, {Duration timeout = const Duration(seconds: 20)}) async {
    final sw = Stopwatch()..start();
    while (!p.allMatches(output).isNotEmpty) {
      if (sw.elapsed > timeout) {
        throw TimeoutException('did not see $p in output:\n$output');
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('WSL launcher run + OSC133 wrapper behaves like a real interactive shell',
      (tester) async {
    final script = 'cd ~ 2>/dev/null\n$_wrapperScript';
    final pty = await Pty.start(
      r'C:\Users\illya\AppData\Local\Microsoft\WindowsApps\ubuntu.exe',
      arguments: ['run', script],
      columns: 80,
      rows: 25,
      environment: {
        'SSTERM_EXACT_ENV': '1',
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'TERM_PROGRAM': 'ssterm',
        'WSLENV': '',
      },
      ackRead: true,
    );

    final collector = _Collector(pty);

    // Should see the OSC 133;D marker (precmd hook firing once at prompt) AND
    // the OSC 7 cwd marker pointing at the Linux home dir, proving:
    //  1. OSC 133 shell integration is actually live (this was the whole point).
    //  2. `cd ~` took effect before the wrapper ran (not stuck in /mnt/c/...).
    await collector.waitFor(RegExp(r'\x1b\]133;D'));
    await collector.waitFor(RegExp(r'\x1b\]7;file://[^\x1b]*/home/'));

    // Now drive it like a real interactive shell: run a command and check
    // we get real line-editing / prompt behavior (not a dumb pipe) and a
    // fresh OSC 133;C ... ;D cycle around it.
    pty.write(Uint8List.fromList(utf8.encode('echo WSL_PROBE_OK\r')));
    await collector.waitFor('WSL_PROBE_OK');

    pty.write(Uint8List.fromList(utf8.encode('pwd\r')));
    await collector.waitFor(RegExp(r'/home/\w+'));

    print('=== FULL OUTPUT ===');
    print(collector.output);

    pty.kill();
    pty.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
