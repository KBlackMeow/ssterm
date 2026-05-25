# ssterm

A cross-platform desktop terminal built with Flutter — local shell, SSH and SFTP
in a tabbed dark UI.

---

## Planned

The items below are **not implemented yet**; they describe where ssterm is
heading, not what it does today.

### Security workbench
- **Vulnerability detection** — scan connected hosts for known
  misconfigurations and CVE-related signals.
- **Malware / trojan screening** — inspect processes, cron jobs, startup
  items and suspicious files.
- **Risk monitoring** — alerts for anomalous logins, privilege changes and
  resource spikes.

### Ops agent
- Natural-language tasks over SSH (e.g. "show disk usage on all web nodes").
- Guided remediation with context from terminal output and SFTP.
- Review gate before destructive commands.

### Distribution
- Linux and Windows release builds. The stack supports them, but only macOS
  is exercised today.

---

## Features

### Terminal
- **Local shell** — PTY-backed terminal with `xterm-256color`, truecolor
  and OSC 7 cwd tracking.
- **Auto shell discovery** — `zsh`, `bash`, `fish`, etc. on macOS/Linux; WSL
  distros and Git Bash on Windows.
- **Pre-raised FD limit** — bumps `RLIMIT_NOFILE` on startup so plugin-heavy
  zsh setups (autosuggestions, fast-syntax-highlighting, autocomplete) don't
  exhaust macOS's default soft limit of 256.

### SSH / SFTP
- **SSH sessions** over `dartssh2` with password or private-key auth
  (optional passphrase).
- **SFTP browser** — browse, download, upload, rename, mkdir, delete;
  concurrent transfers with a progress panel.
- **`~/.ssh/config` import** — pick hosts directly from your existing config.
- **Saved hosts** — encrypted credential storage with host-key TOFU
  verification (`~/.ssterm/known_hosts`).
- **Jump host / ProxyJump** — single-hop bastion via `forwardLocal`.
- **Port forwarding** — local, remote and dynamic (SOCKS5) rules per host.
- **Keepalive + auto-reconnect** — configurable interval and transparent
  reconnect on drop.
- **Session logs** — raw stream written to `~/.ssterm/logs/` (replayable
  with `cat`).

### Workspace
- **Tabs and split panes** — multiple sessions per window, horizontal or
  vertical split per tab.
- **Settings panel** — terminal palette, font, wallpaper, frosted glass.
- **Command picker** — preset snippets driven by `assets/scripts/cmd.json`.

---

## Tech stack

| Component         | Package                                           |
|-------------------|---------------------------------------------------|
| UI framework      | [Flutter](https://flutter.dev) (Material 3, dark) |
| Terminal emulator | [xterm](packages/xterm) (vendored)                |
| Local PTY         | [flutter_pty](packages/flutter_pty) (vendored)    |
| SSH / SFTP        | [dartssh2](https://pub.dev/packages/dartssh2)     |

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.11`,
  see `pubspec.yaml`)
- macOS: Xcode command-line tools (for `flutter run -d macos`)
- For SSH key auth: keys readable from your user account (same as OpenSSH)

## Getting started

```bash
git clone <repository-url>
cd ssterm
flutter pub get
flutter run -d macos
```

Release build:

```bash
flutter build macos
```

The app binary is produced under `build/macos/Build/Products/`.

## Usage

1. **Local tab** — opens automatically on launch with your `$SHELL`.
2. **New SSH / SFTP** — click **+** in the tab bar → **Connect…**, or pick a
   host from `~/.ssh/config` / saved hosts.
3. **SFTP** — toggle the panel from the toolbar; right-click entries to
   download (defaults to `~/Downloads`), rename, mkdir or delete.
4. **Split** — toolbar split button (or right-click in the terminal) to
   split the active tab horizontally or vertically.

## Project layout

```
lib/
  main.dart        # App shell, tabs, local/SSH terminal wiring
  dialogs/         # Connect dialog (auth, forwarding, jump host)
  models/          # SshHost, AppConfig, PortForwardRule, ...
  services/        # SSH connection, port forwarding, session logger, ...
  utils/           # Small helpers (e.g. FD-limit bump)
  views/           # SFTP browser, SSH session view, settings
  widgets/         # Terminal surface, split view, transfer panel, ...
packages/
  flutter_pty/     # Native PTY plugin (vendored)
  xterm/           # Terminal emulator (vendored)
```

## License

_Not yet specified._
