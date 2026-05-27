/// Returns a POSIX shell script that launches the user's login shell inside
/// a clean environment with OSC 7 (working-directory reporting) wired up.
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
if [ -f "$HOME/.zshrc" ]; then
  . "$HOME/.zshrc"
fi
case " ${precmd_functions[*]} " in
  *" __ssterm_cwd "*) : ;;
  *) precmd_functions+=(__ssterm_cwd) ;;
esac
__ssterm_cwd
EOF
    cat >"$tmpdir/.zlogin" <<'EOF'
if [ -f "$HOME/.zlogin" ]; then
  . "$HOME/.zlogin"
fi
zshexit() { rm -rf "$ZDOTDIR"; }
EOF
    exec env ZDOTDIR="$tmpdir" "$shell" -il
    ;;
  bash)
    ENV=/dev/fd/3 exec "$shell" --posix --noprofile -i 3<<'RCEOF'
set +o posix
__ssterm_cwd() {
  printf '\033]7;file://%s\033\\' "$PWD"
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
__ssterm_cwd
RCEOF
    ;;
  *)
    exec "$shell" -i
    ;;
esac
''';
