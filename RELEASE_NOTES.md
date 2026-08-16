# Release Notes — SSTerm v1.7

_Covers everything since v1.6.0 · 219 commits · July 12 – August 16, 2026_

---

## 🤖 AI Agent

The agent saw its largest evolution yet — from a markdown-fence parser to a fully structured, provider-native, budgeted execution engine.

- **Model Context Protocol (MCP)** — Connect MCP servers via local `stdio` or Streamable HTTP in **Settings → Agent → MCP**. Discovered tools are surfaced to the agent, results stream back into expandable cards, and reconnect now follows a fixed interval.

- **Native tool calling** — OpenAI-compatible providers, Claude, and Gemini now receive typed tool schemas and return structured `tool_call` blocks, replacing loose fenced-JSON parsing. Ollama keeps the compatible text-protocol fallback so local models continue to work.

- **AI command-risk classification** — The agent classifies every command as normal, warning, or dangerous. Host rules can only raise the level, catastrophic rules stay mandatory, and result cards display the final classification alongside the command's inferred purpose.

- **Background-only execution** — The single Agent now runs commands in isolated background processes or SSH channels, with live output streaming and the ability to stop stalled commands. Legacy visible-terminal command capture, OSC 133 hooks, and the retired Agent1 shell protocol were removed.

- **SSH execution & Windows job objects** — Agent commands run over SSH channels on remote sessions; on Windows, commands are routed through native Job Objects so process trees are cleaned up deterministically.

- **Durable execution** — Every run is bounded by a resource budget (model requests, shell calls, elapsed time), preserves its outcome as a structured terminal event, recovers once from context-limit overflow, and persists bounded output artifacts with per-session expiry and restricted permissions.

- **Adaptive context compaction** — Long conversations compact automatically using provider token budgets, with exact-plus-estimated accounting from captured provider usage and reasoning-token counts surfaced in the UI. Model outputs default to a 32k cap.

- **Provider presets & compatible catalog** — Added the GLM provider preset, a compatible-provider catalog routed by protocol, and streamlined preset configuration with per-model output limits.

- **Interactive tools** — New `ask_user_question` card pauses the loop for structured decisions, and `edit_file` performs precise match/replace edits with a hand-rolled LCS diff preview.

- **Agent UX** — Command history persists across sessions; chat history is selectable; a clear button resets the conversation; tool-output previews collapse; the transcript auto-follows the latest output; and a unified command-picker ties it together.

---

## ⚡ Terminal & PTY

- **Terminal capability queries** — Added a bounded DCS parser and honest, deterministic responses to termcap/device-attribute queries (DA1, DA2, `CSI ? u`, `CSI > 0 q`, OSC 11, `XTGETTCAP`). SSTerm advertises only what it implements and never identifies as iTerm2.

- **Fish shell support** — Fish now starts cleanly in every session, enabled by the capability-query responses above.

- **Login PATH restored** — Local shells regain their login `PATH` for correct tool discovery.

- **PowerShell / cmd local execution** — Local shell command execution now supports PowerShell and cmd.exe on Windows.

- **Upstream xterm sync** — Vendored xterm updated with the latest upstream fixes; repeated device-attribute queries are answered correctly.

---

## 🎨 Settings

- **Full redesign** — The settings console was redesigned and modularized, with instant switching, restored Material surfaces, and a dedicated home for provider presets, MCP servers, and agent configuration.

---

## 📁 SFTP & File Editor

- **In-app file editor** — Double-click a remote file (or use the Edit menu) to open a full `FileEditorView` tab with extension-based language detection and syntax highlighting via `flutter_code_editor`.

- **Panel polish** — The SFTP panel uses a fixed default width, fixing `RenderFlex` overflow at narrow widths; editor gutters were narrowed and line numbers disabled; network calls now carry a timeout.

---

## 🪟 Windows

- **WSL integration** — WSL tabs launched via the distro launcher now get OSC 133 shell integration, and the app no longer hangs on window close with an open WSL tab.

- **Startup diagnostics** — PTY startup diagnostics are exposed when PowerShell is blocked by execution policy, with a fallback path when startup is policy-blocked.

- **Rendering & windowing** — Refined Windows font rendering and fixed window dragging when all tabs are closed.

---

## 🍎 macOS

- **Unified file picking** — Native file picking is unified across the app.

- **Build tooling** — The DMG build script now lives at the repository root.

---

## 🔧 Notable Fixes

- Window drag when all tabs are closed on Windows
- MCP tool-call format unified under a single `mcp` name with a `[Tool result]` envelope
- Settings Material surfaces restored
- Compaction no longer splits `tool_call` / `tool_result` pairs
- Agent output artifacts expire with their session and are permission-restricted
