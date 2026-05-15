# ssterm

**ssterm** is a cross-platform desktop terminal built with Flutter. It combines a modern SSH/SFTP workflow with a long-term vision: built-in security checks and an AI agent that helps you operate remote systems safely.

## Goals

### 1. Modern terminal with SSH & SFTP

A tabbed, dark-themed UI for day-to-day remote work:

- **Local shell** — PTY-backed terminal with xterm-256color and truecolor support
- **SSH sessions** — interactive remote shells over `dartssh2`
- **SFTP browser** — browse, download, upload, rename, mkdir, and delete files on remote hosts
- **Unified connection flow** — one dialog to open either a terminal or an SFTP tab; hosts can be picked from `~/.ssh/config`
- **Authentication** — password or private key (with optional passphrase)

### 2. Vulnerability detection, malware screening & risk monitoring

Planned security layer integrated into the same app you use to SSH:

- **Vulnerability detection** — scan connected hosts for known misconfigurations and CVE-related signals
- **Malware / trojan screening** — inspect processes, cron jobs, startup items, and suspicious files
- **Risk monitoring** — ongoing alerts for anomalous logins, privilege changes, and resource spikes

### 3. Agent-assisted operations

Planned AI agent features for DevOps and SRE workflows:

- Natural-language tasks over SSH (e.g. “show disk usage on all web nodes”)
- Guided remediation with context from terminal output and SFTP
- Safer change workflows with review before destructive commands

## Current status

| Area | Status |
|------|--------|
| Local terminal (PTY + xterm) | ✅ Available |
| SSH terminal | ✅ Available |
| SFTP file manager | ✅ Available |
| `~/.ssh/config` host import | ✅ Available |
| Vulnerability / malware scans | 🚧 Planned |
| Risk monitoring | 🚧 Planned |
| Ops agent | 🚧 Planned |

Primary development target today is **macOS**. Other Flutter desktop targets (Linux, Windows) are supported by the stack but may need platform-specific testing.

## Screenshots

_Add screenshots here as the UI stabilizes._

## Tech stack

| Component | Package |
|-----------|---------|
| UI framework | [Flutter](https://flutter.dev) (Material 3, dark theme) |
| Terminal emulator | [xterm](packages/xterm) (vendored) |
| Local PTY | [flutter_pty](https://pub.dev/packages/flutter_pty) |
| SSH / SFTP | [dartssh2](https://pub.dev/packages/dartssh2) |

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.11`, see `pubspec.yaml`)
- macOS: Xcode command-line tools (for `flutter run -d macos`)
- For SSH key auth: keys readable from your user account (same as OpenSSH)

## Getting started

```bash
# Clone and enter the repo
git clone <repository-url>
cd ssterm

# Install dependencies
flutter pub get

# Run on macOS
flutter run -d macos
```

Release build:

```bash
flutter build macos
```

The app binary is produced under `build/macos/Build/Products/`.

## Usage

1. **Local tab** — opens automatically on launch with your `$SHELL` (default `zsh`).
2. **New SSH / SFTP** — click **+** in the tab bar → **Connect…**
   - Choose **Terminal** for an SSH shell tab, or **SFTP** for a file browser tab.
   - Enter host, port, user, and password or private key path.
   - Select a host from the list to pre-fill fields from `~/.ssh/config`.
3. **SFTP** — right-click or use the toolbar to download files (saved to `~/Downloads`), rename, create folders, or delete entries.

## Project layout

```
lib/
  main.dart              # App shell, tabs, local/SSH terminal wiring
  dialogs/
    connect_dialog.dart  # SSH/SFTP connection UI
  views/
    sftp_view.dart       # Remote file browser
  models/
    ssh_host.dart        # ~/.ssh/config parser
packages/
  xterm/                 # Terminal emulator (local fork)
```

## Roadmap

- [ ] Security scan modules (vuln, malware, baseline checks)
- [ ] Host risk dashboard and alerting
- [ ] Ops agent (prompt → plan → execute with guardrails)
- [ ] Session profiles, jump hosts, and port forwarding
- [ ] Linux and Windows release builds

## Contributing

Contributions are welcome. Please open an issue before large changes so we can align on scope—especially for security scanning and agent behavior.

## License

_Specify license here (e.g. MIT, Apache-2.0) if applicable._
