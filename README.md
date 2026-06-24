# SSTerm

**A cross-platform desktop terminal with a built-in AI agent — local shell, SSH, and SFTP in a unified dark tabbed UI.**

![demo](video.gif)

---

## ✨ Highlights

- **🤖 AI Agent** — Chat with an AI assistant beside your terminal. Auto-execute commands, capture output, review dangerous operations, and let the agent write files — all with full terminal context.
- **🔀 Split Panes** — Horizontal and vertical splits within every tab. Run a local shell and an SSH session side-by-side, or monitor logs while editing remotely.
- **📁 SFTP Browser** — Browse, upload, download, rename, and manage remote files from a dockable panel. Concurrent transfers with a live progress queue. Drag-and-drop upload support.
- **🔐 Full SSH Client** — Password and private-key auth, `~/.ssh/config` import, jump host / ProxyJump, port forwarding (local, remote, SOCKS5), keepalive with auto-reconnect, and session logging.
- **🎨 Deep Customization** — 9 terminal theme presets, custom colors, JetBrains Mono / SF Mono / Monaco with CJK fallback, cursor shape & blink, wallpaper with frosted glass blur and opacity.
- **⚡ Local Shell** — PTY-backed with TrueColor, auto shell discovery (zsh, bash, fish, WSL, Git Bash), and pre-raised file descriptor limits for plugin-heavy setups.
- **🖥️ Cross-Platform** — macOS (primary), Windows, Linux. Mobile (iOS/Android) for SSH & SFTP.

---

## 🤖 AI Agent

The terminal-aware agent panel is the standout feature — converse with an AI assistant that sees your active terminal, executes commands, and iterates on results.

| Capability | Description |
|---|---|
| **Multi-provider** | ChatGPT (OpenAI), Claude (Anthropic), Gemini (Google), DeepSeek, Ollama (local) |
| **Session context** | Active tab, working directory, and date/time sent on first turn |
| **Auto-execute mode** | Agent runs commands and iterates on captured output automatically |
| **Manual mode** | Agent proposes commands; click **Exec** to run with safety checks |
| **Dangerous-command gate** | 25+ built-in safety rules; destructive commands pause for approval |
| **File-write proposals** | Agent proposes file writes with a diff preview; apply or reject per-file |
| **Web search** | Brave Search integration for current web results (configurable) |
| **Built-in skills** | `disk-space`, `git-bisect`, `port-conflict`, `verify-fix` — toggleable per skill |
| **Streaming replies** | Real-time text with reasoning/thinking channel display and Markdown rendering |

---

## 🔀 Split Panes & Tabs

- **Tabs** — Create local shell, SSH, or settings tabs. Tab bar with horizontal scroll, keyboard shortcuts (Cmd+W / Ctrl+W to close).
- **Splits** — Split any tab horizontally or vertically. Drag-to-resize dividers. Secondary pane supports local shell or SSH sessions.
- **Toolbar** — One-click access to new tab, command picker, AI panel, SFTP panel, transfer queue, split controls, and settings.

---

## 📁 SFTP Browser

| Feature | Description |
|---|---|
| **File operations** | Browse, upload, download, rename, mkdir, delete |
| **Transfer queue** | Concurrent transfers with live progress, pause/resume/cancel per task |
| **Drag & drop** | Drop files onto the terminal to upload |
| **Panel docking** | Bottom or right side, persisted in config |
| **Path sync** | SFTP directory follows the SSH terminal's working directory (OSC 7) |

---

## 🔐 SSH & Port Forwarding

| Feature | Description |
|---|---|
| **Authentication** | Password, private key (with optional passphrase), default identity files |
| **Host key** | TOFU verification via `~/.ssterm/known_hosts` |
| **Config import** | Pick hosts from `~/.ssh/config` (Host, Hostname, Port, User, IdentityFile) |
| **Saved hosts** | Credentials encrypted in macOS Keychain |
| **Jump host** | Single-hop ProxyJump / bastion forwarding |
| **Port forwarding** | Local (`-L`), remote (`-R`), and dynamic SOCKS5 (`-D`) with per-rule toggles |
| **Keepalive** | Configurable heartbeat interval (15s / 30s / 60s) |
| **Auto-reconnect** | Transparent reconnection on connection drop |
| **Session logging** | Raw stream to `~/.ssterm/logs/`, replayable with `cat` |

---

## 🎨 Customization

- **Themes** — 9 presets from VS Code, Windows Terminal, macOS Terminal, iTerm2, and GNOME Terminal, plus full custom color picker.
- **Fonts** — JetBrains Mono, SF Mono Powerline, Monaco, plus system fonts. CJK fallback (Simplified/Traditional Chinese, Japanese).
- **Cursor** — Block, underline, or vertical bar; configurable blink speed.
- **Wallpaper** — Import any image, adjust Gaussian blur (frosted glass), opacity, and background fill.
- **Commands** — Built-in command panel with one-click insertion. Add, edit, and delete custom commands.

---

## ⚡ Local Shell

- PTY-backed with `xterm-256color` and TrueColor (24-bit).
- Auto-detects zsh, bash, fish, tcsh, ksh, sh, dash on macOS/Linux; WSL distros, CMD, PowerShell, and Git Bash on Windows.
- Shell integration via OSC 7 (working directory tracking) and OSC 133 (command boundary markers for the AI agent).
- Pre-raises `RLIMIT_NOFILE` at startup to prevent fd exhaustion with plugin-heavy shells.

---

## 🖥️ Platform Support

| Platform | Local Shell | SSH | SFTP | AI Agent |
|---|---|---|---|---|
| **macOS** | ✅ | ✅ | ✅ | ✅ |
| **Windows** | ✅ WSL, CMD, PowerShell, Git Bash | ✅ | ✅ | ✅ |
| **Linux** | ✅ | ✅ | ✅ | ✅ |
| **iOS** | — | ✅ | ✅ | ✅ |
| **Android** | — | ✅ | ✅ | ✅ |

---

## 🛠️ Tech Stack

| Component | Technology |
|---|---|
| UI framework | [Flutter](https://flutter.dev) (Material 3 Dark) |
| Terminal emulator | [xterm](packages/xterm) (vendored) |
| Local PTY | [flutter_pty](packages/flutter_pty) (vendored) |
| SSH / SFTP | [dartssh2](https://pub.dev/packages/dartssh2) |

---

## 🚀 Getting Started

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

**Requirements:** [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.11`), macOS with Xcode command-line tools.

---

## 📂 Project Layout

```
lib/
  main.dart          # App shell, tabs, local/SSH terminal state
  dialogs/           # Connect dialog (auth, port forwarding, jump host)
  models/            # SshHost, AppConfig, Command, PortForwardRule …
  services/          # SSH connection, port forwarding, session logger, LLM …
  utils/             # Helpers (FD limit, SSH fingerprint …)
  views/             # SFTP browser, SSH session view, settings panel
  widgets/           # Terminal surface, split view, transfer panel, AI panel …
packages/
  flutter_pty/       # Native PTY plugin (vendored)
  xterm/             # Terminal emulator (vendored)
```

---

## 📋 Roadmap

- **Attach terminal context** — manually attach recent terminal output or failed-command context to a fresh agent prompt
- **Command blocks** — structured command history with selectable command/output blocks for agent context
- **Linux / Windows builds** — the stack supports them; macOS is the current primary platform

---

## 📄 License

Apache 2.0
