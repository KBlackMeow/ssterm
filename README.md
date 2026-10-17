# SSTerm

**A cross-platform desktop terminal with a built-in AI agent — local shell, SSH, and SFTP in a unified dark tabbed UI.**

![demo](video.gif)

---

## ✨ Highlights

- **🤖 AI Agent** — Chat with an AI assistant beside your terminal. Run commands in independent background sessions, review file diffs, attach images, and resume saved conversations — with command risk checks and automatic context compaction.
- **🔀 Split Panes** — Horizontal and vertical splits within every tab. Run a local shell and an SSH session side-by-side, or monitor logs while editing remotely.
- **📁 SFTP Browser** — Browse, upload, download, rename, and manage remote files from a dockable panel. Syntax-highlighted remote file editing, concurrent transfers with a live progress queue, staged uploads, and drag-and-drop support.
- **🔐 Full SSH Client** — Password and private-key auth, `~/.ssh/config` import, jump host / ProxyJump, port forwarding (local, remote, SOCKS5), keepalive with auto-reconnect, and session logging.
- **🎨 Deep Customization** — 9 terminal theme presets, custom colors, bundled JetBrains Mono plus platform-native fonts with CJK fallback, cursor shape & blink, wallpaper with frosted glass blur and opacity.
- **⚡ Local Shell** — Rust-backed terminal parsing and PTY I/O with TrueColor, OSC 7-integrated shell discovery (zsh, bash, fish, WSL, Git Bash), and pre-raised file descriptor limits for plugin-heavy setups.
- **🖥️ Cross-Platform** — macOS (primary), Windows, Linux. Mobile (iOS/Android) for SSH & SFTP.

---

## 🤖 AI Agent

The tab-scoped agent panel is the standout feature — converse with an AI assistant that executes local or SSH commands in its own background session and iterates on structured results. Create a fresh conversation or resume a saved session from the session picker.

| Capability | Description |
|---|---|
| **Multi-provider** | ChatGPT (OpenAI), Claude (Anthropic), Gemini (Google), DeepSeek, Ollama (local), plus a compatible-provider catalog (OpenRouter, Kimi, Qwen, GLM, Mistral, MiniMax, SiliconFlow) and custom OpenAI/Anthropic-compatible endpoints |
| **Native tool calling** | OpenAI-compatible providers, Claude, and Gemini receive typed tool schemas and return structured tool calls; Ollama keeps the compatible text protocol fallback |
| **Session context** | A tab-scoped session context sends the active tab, working directory, and date/time on the first turn; verified command cwd carries forward to later commands and relative file operations |
| **Saved sessions** | Create, resume, and delete conversations; sessions are saved after the first message |
| **Task controls** | Stop a running task, queue follow-up input, and use slash command completion for session actions and skills |
| **Auto-execute mode** | Ordinary and warning commands run automatically; dangerous commands pause for approval |
| **Cautious mode** | Ordinary commands run directly; warning and dangerous commands require confirmation |
| **Three-level command risk** | AI classifies commands as normal, warning, or dangerous; host rules can only raise the level, and result cards show the final classification |
| **File writes & edits** | Create or replace files, or make precise text replacements, with a diff preview and per-file Apply / Reject review |
| **Bounded reads** | Read local or SSH files by byte range, search one file for matching lines, and retrieve stored command output by range when a result was shortened |
| **Image support** | Attach images to prompts and let vision-capable models inspect local workspace images through the image tool |
| **Provider speed test** | Wait up to 30 seconds for a selected provider/model's first output, then sample for 5 seconds; show average tokens/s, ms/token, and first-token latency, with estimated counts clearly labeled |
| **Context management** | Automatic conversation compaction, token usage display, and per-model context window and maximum output settings |
| **Command results** | Structured command history and expandable result cards show command purpose, risk, output, and execution outcome |
| **Web search** | Brave Search integration for current web results (configurable) |
| **Custom skills** | Add user-defined skills from Settings or share them through `~/.agents/skills/<id>/SKILL.md`; no built-in playbooks are enabled by default |
| **MCP integration** | Connect user-configured Model Context Protocol servers through local stdio or Streamable HTTP, then expose their discovered tools to the agent |
| **Streaming replies** | Real-time text with reasoning/thinking channel display and Markdown rendering |

### Tool calling

SSTerm advertises only the tools enabled for the current agent session: shell commands, questions, web search, file writes/edits, local image inspection, enabled custom skills, and configured MCP tools. For providers with native support, calls and results remain structured through the provider's conversation format; the agent executes at most one actionable call per turn. Ollama uses the existing fenced-JSON/text protocol so local models continue to work.

Native calls use the same safeguards as the compatibility path: dangerous commands stop for review, file changes are presented as apply/reject proposals, and MCP calls go through SSTerm's existing tool executor. Tool-call cards redact sensitive argument values and truncate unusually long values before displaying them.

### MCP servers

Configure MCP servers in **Settings → Agent → MCP**. SSTerm supports local `stdio` servers (a command plus arguments) and remote Streamable HTTP endpoints. It discovers each enabled server's tools and makes those tools available only while MCP is enabled for the agent. Results—including tool errors—are shown in expandable MCP result cards and fed back to the agent for the next turn.

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
| **In-app file editor** | Double-click a remote file to open a syntax-highlighted editor tab (language detection, line folding) and save changes back over SFTP |
| **Transfer queue** | Concurrent transfers with live progress, pause/resume/cancel per task |
| **Staged uploads** | Upload to a temporary sibling file with pipelined writes, then rename into place after completion |
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
- **Fonts** — Bundled JetBrains Mono plus platform-native fonts. CJK fallback (Simplified/Traditional Chinese, Japanese).
- **Cursor** — Block, underline, or vertical bar; configurable blink speed.
- **Wallpaper** — Import any image, adjust Gaussian blur (frosted glass), opacity, and background fill.
- **Commands** — Built-in command panel with one-click insertion. Add, edit, and delete custom commands.

---

## ⚡ Local Shell

- Rust-backed terminal parsing, screen buffers, and native PTY I/O with `xterm-256color` and TrueColor (24-bit).
- Batched output and flow control for high-volume local and SSH sessions; resize reflow, CJK/emoji cell handling, terminal query responses, and mouse reporting for interactive TUIs.
- Windows uses ConPTY with bundled OpenConsole components and a system ConPTY fallback.
- Auto-detects OSC 7-integrated zsh, bash, and fish on macOS/Linux; compatible WSL distros, CMD, PowerShell, and Git Bash on Windows.
- Visible terminal shells use OSC 7 for their own working-directory tracking.
  Agent commands run in independent background processes or SSH channels, and
  their verified cwd drives later Agent commands and relative file operations;
  the active terminal pane's OSC 7 cwd is used as their starting context.
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
| Terminal emulator | [Rust terminal core](native/terminal_core) for parsing and screen state + [xterm](packages/xterm) (vendored) for rendering and input |
| Local PTY | [Rust PTY core](native/pty_core) + [flutter_pty](packages/flutter_pty) (vendored bridge), with ConPTY on Windows |
| SSH / SFTP | [dartssh2](https://pub.dev/packages/dartssh2) |
| AI Agent | [mcp_dart](https://pub.dev/packages/mcp_dart) (MCP) + provider-native tool calling |
| File editor | [flutter_code_editor](https://pub.dev/packages/flutter_code_editor) + [highlight](https://pub.dev/packages/highlight) |
| Credential storage | [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) (macOS Keychain) |

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

**Requirements:** [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart `^3.11.1`), macOS with Xcode command-line tools.

---

## 📂 Project Layout

```
lib/
  app/               # Desktop & mobile app shells (tabs, panes, mobile nav)
  main.dart          # Bootstrap, service init, tab/connection state
  dialogs/           # Connect dialog (auth, port forwarding, jump host)
  io/                # PTY output pipe + metrics
  models/            # SshHost, AppConfig, Command, PortForwardRule, AgentConfig, McpServerConfig, Skill …
  services/          # SSH, SFTP, port forwarding, session logger, LLM, MCP, skills, agent execution …
  utils/             # Helpers (FD limit, SSH fingerprint …)
  views/             # SFTP browser, SSH session view, in-app file editor
  views/settings/    # Settings console (themes, providers, MCP, agent, commands, safety)
  widgets/           # Terminal surface, split view, transfer panel, AI panel …
packages/
  flutter_pty/       # Native PTY plugin (vendored)
  xterm/             # Terminal rendering & input (vendored)
native/
  terminal_core/     # Rust terminal parser & screen buffers
  pty_core/          # Rust PTY lifecycle & I/O (Unix PTY / Windows ConPTY)
```

---

## 📋 Roadmap

- **Attach terminal context** — manually attach recent terminal output or failed-command context to a fresh agent prompt
- **Command blocks** — structured command history with selectable command/output blocks for agent context
- **Linux / Windows builds** — the stack supports them; macOS is the current primary platform

---

## 📄 License

Apache 2.0
