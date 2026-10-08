# SSTerm v1.8.0

This release improves terminal performance and TUI compatibility, expands AI Agent session and image support, and strengthens SSH, SFTP, and Windows local terminal reliability.

## 🤖 AI Agent

- **Session management** — Create, resume, and delete saved sessions. Sessions are now saved after the first message, and the session history menu has a more stable layout.
- **Smoother task interaction** — Added a stop button, queued input, and slash command completion. Fixed tool call states after interruption and automatic scrolling during streamed replies.
- **Image support** — Attach images and inspect images in the workspace, with improved image message and reasoning state compatibility across providers. Text files are no longer incorrectly routed to the image tool.
- **Model settings** — Configure context windows and maximum output lengths per model. Improved token usage parsing and automatic retries when providers return rate limit errors.
- **Shared Skills** — Discover and load skills from `~/.agents/skills/<id>/SKILL.md` to share them with other agent tools.
- **Execution reliability** — Simplified the Agent execution flow and fixed corrupted background command output at UTF-8 chunk boundaries.

## ⚡ Terminal Performance & Compatibility

- **Rust terminal and PTY cores** — Moved terminal output parsing and screen buffer processing to Rust. Batched reads and flow control improve responsiveness for local terminals and high-volume SSH output.
- **Resize fixes** — Improved content preservation and line reflow when resizing windows, split panes, or the Agent panel. Fixed size synchronization during local PTY startup.
- **TUI rendering** — Fixed glyph artifacts in animated TUIs, improved Claude TUI compatibility, and corrected modern emoji cell widths.
- **Terminal protocol compatibility** — Improved device attribute responses, foreground color queries, and mouse reporting. Fixed CJK character handling in OSC/DCS payloads.

## 🔐 SSH & SFTP

- **Connection reliability** — Strengthened terminal and SSH session lifecycle management and improved high-throughput output handling.
- **Safer uploads** — SFTP uploads now use temporary files and pipelined writes to reduce the impact of interrupted transfers on destination files.
- **Editor improvements** — Fixed caret following after Enter and scroll boundary handling in the remote file editor.

## 🪟 Windows & Interface

- **Local terminal improvements** — Integrated updated ConPTY / OpenConsole components and improved terminal query responses, WSL discovery, and validation of shells launched from fixed paths.
- **Visual consistency** — Unified Agent heading and dialog typography on Windows and refreshed application icons.
- **Font updates** — Removed bundled Apple fonts while retaining JetBrains Mono, platform-native fonts, and CJK fallback fonts.
