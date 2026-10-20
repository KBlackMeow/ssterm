#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
nano_path="$(command -v nano)"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

cc -std=gnu11 -O2 -pthread \
  -o "$build_dir/pty_paste_test" \
  "$repo_root/test/native/pty_paste_test.c"

run_case() {
  python3 - "$build_dir/pty_paste_test" "$nano_path" "$1" <<'PY'
import os
import subprocess
import sys

executable, nano_path, mode = sys.argv[1:]
environment = os.environ.copy()
if mode == 'legacy':
    environment['SSTERM_USE_RUST_PTY'] = '0'
else:
    environment.pop('SSTERM_USE_RUST_PTY', None)
try:
    result = subprocess.run([executable, nano_path], env=environment, timeout=10)
except subprocess.TimeoutExpired:
    print(f'{mode} PTY paste timed out after 10 seconds', file=sys.stderr)
    sys.exit(124)
sys.exit(result.returncode)
PY
}

echo 'Legacy PTY:'
run_case legacy

if [[ "$(uname)" == Darwin ]]; then
  rust_library="$repo_root/build/macos/Build/Products/Debug/SSTerm.app/Contents/MacOS/libssterm_pty_core.dylib"
  if [[ -f "$rust_library" ]]; then
    cp "$rust_library" "$build_dir/libssterm_pty_core.dylib"
    echo 'Rust PTY:'
    run_case rust
  fi
fi
