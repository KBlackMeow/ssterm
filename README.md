# SSTerm

A cross-platform desktop terminal — local shell, SSH, and SFTP in a unified dark tabbed UI.

---

## Features

### Terminal

- **Local shell** — PTY-backed with `xterm-256color`, TrueColor, and OSC 7 working directory tracking
- **Auto shell discovery** — detects `zsh`, `bash`, `fish`, etc. on macOS/Linux; WSL distros and Git Bash on Windows
- **Pre-raised FD limit** — bumps `RLIMIT_NOFILE` at startup so plugin-heavy zsh setups (autosuggestions, fast-syntax-highlighting) don't exhaust macOS's default 256 soft limit

### SSH / SFTP

- **SSH sessions** — powered by `dartssh2`, supports password and private-key (with optional passphrase) auth
- **SFTP browser** — browse, upload, download, rename, mkdir, delete; concurrent transfers with a live progress panel
- **`~/.ssh/config` import** — pick hosts directly from your existing config file
- **Saved hosts** — credentials encrypted in the macOS Keychain; host-key TOFU verification via `~/.ssterm/known_hosts`
- **Jump host / ProxyJump** — transparent single-hop bastion forwarding
- **Port forwarding** — local, remote, and dynamic (SOCKS5) rules configured per host
- **Keepalive + auto-reconnect** — configurable heartbeat interval with transparent reconnection on drop
- **Session logs** — raw stream written to `~/.ssterm/logs/`, replayable with `cat`

### Workspace

- **Tabs and split panes** — each tab can be split horizontally or vertically for multiple concurrent sessions
- **Command panel** — one-click command insertion from the toolbar; built-in official commands are read-only, users can freely add, edit, and delete custom commands
- **Settings panel** — terminal themes (presets + custom colors), fonts (JetBrains Mono / SF Mono / Monaco with CJK fallback), cursor shape and blink, wallpaper (blur + opacity), frosted glass effects

---

## Preview

![demo](video.gif)

| Feature | Description |
|---------|-------------|
| Dark tab bar | Lightweight chrome with top tab strip and toolbar |
| Split panes | Horizontal / vertical split within a single tab |
| SFTP panel | Overlaid on the terminal, toggleable from the toolbar |
| Frosted glass | SFTP panel, context menus, and command menu all support backdrop blur |
| Wallpaper | Import any local image, adjust blur and opacity |

---

## Tech Stack

| Component | Package |
|-----------|---------|
| UI framework | [Flutter](https://flutter.dev) (Material 3 Dark) |
| Terminal emulator | [xterm](packages/xterm) (vendored) |
| Local PTY | [flutter_pty](packages/flutter_pty) (vendored) |
| SSH / SFTP | [dartssh2](https://pub.dev/packages/dartssh2) |

---

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.11`, see `pubspec.yaml`)
- macOS: Xcode command-line tools (`flutter run -d macos`)
- SSH key auth: key files readable by the current user (same as OpenSSH)

---

## Getting Started

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

Output: `build/macos/Build/Products/`

---

## Usage

1. **Local tab** — opens automatically on launch using `$SHELL`
2. **New SSH / SFTP** — click **+** in the tab bar → **Connect…**, or pick from `~/.ssh/config` / saved hosts
3. **SFTP** — toggle the panel from the toolbar; right-click entries to download (defaults to `~/Downloads`), rename, mkdir, or delete
4. **Split** — toolbar split button (or right-click in the terminal) to split the active tab horizontally or vertically
5. **Command panel** — toolbar terminal icon button; select a command to insert it directly into the terminal input; manage custom commands under Settings → Commands

---

## Project Layout

```
lib/
  main.dart          # App shell, tabs, local/SSH terminal state
  dialogs/           # Connect dialog (auth, port forwarding, jump host)
  models/            # SshHost, AppConfig, Command, PortForwardRule …
  services/          # SSH connection, port forwarding, session logger, SFTP download …
  utils/             # Helpers (FD limit, SSH fingerprint …)
  views/             # SFTP browser, SSH session view, settings panel
  widgets/           # Terminal surface, split view, transfer panel, command picker …
packages/
  flutter_pty/       # Native PTY plugin (vendored)
  xterm/             # Terminal emulator (vendored)
```

---

## Roadmap

The following are planned but not yet implemented:

- **Security workbench** — vulnerability detection, malware screening, anomalous login alerts
- **Ops agent** — natural-language SSH operations with a review gate for destructive commands
- **Linux / Windows builds** — the stack supports them; macOS is the current primary platform

---

## License

_Not yet specified._
