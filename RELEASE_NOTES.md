# Release Notes — SSTerm v1.5.1

_June 24, 2026_

---

## 🤖 Agent

- **Structured tool calls** — The agent no longer relies on loose markdown-fence parsing. Commands, web searches, skill invocations, and file writes are now surfaced as structured `tool_call` blocks, making extraction reliable and eliminating false positives from code blocks in replies.

- **Forged command feedback hardening** — Commands injected into the terminal by the agent now carry a fingerprint. The agent loop only feeds back output that is genuinely produced by its own commands, preventing it from being confused by coincidental terminal output or user keystrokes.

## ⚡ Terminal & PTY

- **Async PTY spawn** — `Pty.start` is now fully async and runs `pty_create` in a background isolate with a 30-second timeout. The UI thread never blocks on FFI, and failures surface as typed `PtyStartException` with a restart prompt instead of a silent hang.

- **Kernel deadlock fixed** — Closing a tab with an active text selection no longer deadlocks. The native PTY destroy path now sends `SIGKILL` before `close(ptm)`, so the slave closes immediately and the blocking `read()` returns `EOF` — resolving an AB-BA deadlock between the main and I/O threads.

- **Teardown resource cleanup** — Terminal controllers, gesture detectors, and custom text editing connections are now torn down in the correct order during tab removal, eliminating post-disposal callbacks and stray timer firings.

## 🪟 Windows

- **Sensible defaults** — Windows now defaults to PowerShell (`pwsh` > `powershell` > `cmd`) instead of blindly following `COMSPEC`. Default font size bumped from 12 to 14 pt. WSL and Git Bash inherit the user's full Windows `%PATH%`, so tools like `code` are found out of the box.

- **Tab switch & close stability** — Tab switching now releases text input focus on all inactive tabs and destroys native PTY handles in a background isolate, preventing `ClosePseudoConsole` from freezing the Flutter UI thread. A three-frame deferred teardown gives the surviving tab time to claim keyboard focus first.

## 🍎 macOS

- **Zero-latency title bar clicks** — `mouseDownCanMoveWindow` is swizzled to always return `false`, preventing `NSWindow` from entering its drag-disambiguation tracking loop. Window dragging stays functional via Flutter's `windowManager.startDragging()`. This eliminates the ~200ms click delay that made windowed mode feel sluggish compared to fullscreen.

- **SFTP drag-and-drop restored** — File drag-and-drop is now handled at the `NSWindow` level via `NSDraggingDestination` instead of a full-window `DropTarget` `NSView` that was intercepting mouse events. AppKit only consults the window when no view accepts the drag, so mouse event handling is unaffected.

- **Xcode 26 build warnings silenced** — The two `Metal.xctoolchain` linker search-path warnings are eliminated by disabling the debug dynamic library (`ENABLE_DEBUG_DYLIB = NO`) and patching the Pods xcconfig to inherit `OTHER_LDFLAGS`.

## 🔐 SSH & SFTP

- **VPN switch recovery** — Pressing Enter after a connection drops (e.g., VPN disconnect) no longer crashes on `SSHStateError` when closing stale clients. Manual restart falls back to a full reconnect, and SFTP refreshes cleanly when the underlying client is replaced.

- **SFTP writer abort guard** — `SftpFileWriter.abort()` now checks whether the transfer future has already completed before calling `_doneCompleter.complete()`, preventing a `Bad state: Future already completed` crash when cancelling an upload that finished in the background.

---

## What's Next

- **Attach terminal context** — manually attach recent terminal output to an agent prompt
- **Command blocks** — structured command history with selectable blocks for agent context
- **Linux & Windows primary builds** — the stack supports them; polishing is underway
