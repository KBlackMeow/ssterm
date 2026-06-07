/// Returns a POSIX shell script that launches the user's login shell inside
/// a clean environment with OSC 7 (working-directory reporting) and OSC 133
/// (shell-integration / command boundary markers) wired up.
///
/// OSC 133 is the same protocol used by iTerm2, VS Code, Warp, and Zed —
/// `OSC 133;C` marks the start of command output, `OSC 133;D;<exit_code>`
/// marks the end.  The agent loop relies on these markers to capture the
/// exact bytes a command produced, plus its exit code.
///
/// Handles zsh (ZDOTDIR isolation), bash (ENV fd trick), and a generic
/// fallback for any other POSIX shell.
String buildInteractiveShellWrapper() => r'''
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
# CRITICAL: must run FIRST in precmd_functions so $? still carries the
# user command's exit code.
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
# Save $? on entry so any later command in PROMPT_COMMAND can't clobber it.
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
