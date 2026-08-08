# Agent2 independent background execution — implementation plan

> **For implementation:** Follow this plan task by task. Agent1 remains unchanged throughout; Agent2 is experimental and uses a separate non-PTY command transport.

**Goal:** Add a per-tab Agent2 panel whose `bash` tool executes locally or over the existing SSH client without writing into the visible terminal, so it can be compared safely with the current terminal-driven Agent1.

**Architecture:** Extract a cancellable background-command service behind the existing `Future<CommandResult?>` callback shape. Agent2 gets a distinct overlay key, transcript, working directory, cancellation state, filesystem adapter instance, and layout/config. Agent1 keeps `TerminalCommandExecutor`, terminal injection, OSC-133, and its current UI unchanged.

**Tech stack:** Flutter/Dart, `dart:io Process.start`, dartssh2 `SSHClient.execute`, existing `CommandResult`, Flutter widget tests, Dart unit tests.

---

### Task 1: Build the cancellable local background executor

**Files:**
- Create: `lib/services/background_command_executor.dart`
- Create: `test/services/background_command_executor_test.dart`
- Modify: `lib/io/output_pipe.dart` only if a neutral command-result type/doc change is needed

1. Write tests for the public target/capability classifier: bash and zsh on macOS/Linux are accepted; PowerShell, cmd, WSL, Git Bash, unknown shells, and non-local platforms are rejected with a clear message.
2. Define a small active-command handle interface with an idempotent `cancel()`, plus a `BackgroundCommandExecutor` that accepts timeout, output cap, clock/process launcher seams, cwd, shell option, and cancellation predicate.
3. Start only supported local shells through `Process.start(executable, ['-c', command], runInShell: false)`, with the requested cwd and a noninteractive environment. Do not use terminal/PTY wrappers or terminal-only variables.
4. Immediately and concurrently drain stdout and stderr; preserve their source labels when combining them into the existing `CommandResult.output`; cap retained output and mark `truncated`.
5. Complete only after process exit and both stream drains; map start errors, cancellation, timeout, and normal non-zero exits to explicit command results. Cancellation kills the direct child and awaits stream cleanup.
6. Run `dart format lib/services/background_command_executor.dart test/services/background_command_executor_test.dart` and `flutter test test/services/background_command_executor_test.dart`.

### Task 2: Add the SSH background target without disturbing the interactive session

**Files:**
- Modify: `lib/services/background_command_executor.dart`
- Create: `test/services/background_command_target_test.dart`
- Modify: `lib/app/main_ssh.dart`

1. Add an SSH target constructor that requires a live shared `SSHClient`, remote cwd, and label; reject a disconnected or connecting tab before command dispatch.
2. Execute with `SSHClient.execute(command, environment: ..., workingDirectory: cwd)` (verify the installed dartssh2 API signature first), subscribe to stdout/stderr before awaiting the session, then await both streams and exit status.
3. On timeout/cancel, send TERM to that command session and close only that session. Never close the shared SSH client, SFTP client, terminal SSH session, or port forwards.
4. Route the target into a new private `_executeAgent2Command` host method; retain `_executeAndCapture` unmodified for Agent1.
5. Unit-test target selection and unsupported/disconnected diagnostics; add a fake/session seam if needed rather than relying on a real SSH host.
6. Run `dart format lib/services/background_command_executor.dart lib/app/main_ssh.dart test/services/background_command_target_test.dart` and the two executor test files.

### Task 3: Give Agent2 independent tab lifecycle, cwd, and persisted layout

**Files:**
- Modify: `lib/models/tab_model.dart`
- Modify: `lib/models/app_config.dart`
- Modify: `lib/app/main_local.dart`
- Modify: `lib/app/main_ssh.dart`
- Modify: `test/models/tab_model_test.dart`
- Modify/add: `test/models/app_config_test.dart`

1. Add `agent2PanelVisible`, an Agent2 cwd value/notifier, and one active background-command handle to `AppTab`; initialize cwd from the local tab start directory or the remote login home.
2. Ensure tab close, reconnect/disconnect, and app disposal cancel/await or safely detach only the Agent2 command handle. Do not tear down terminal PTYs or shared SSH transports as part of Agent2 cancellation.
3. Persist a separate Agent2 position and size. Default Agent2 to the opposite dock from Agent1 when possible; preserve old configs by defaulting missing keys.
4. Add deterministic collision handling: when both panels are open they must occupy distinct dock axes; if a user moves Agent2 onto Agent1's dock, automatically flip Agent2 to the opposite side and persist that correction. This prevents nested panels from consuming the same edge twice.
5. Keep Agent2 cwd independent after initialization; file operations and context use it, never terminal OSC-7 cwd. Include the cwd in Agent2's visible/context label.
6. Test defaults, JSON round-trip/backwards compatibility, initial cwd, cancellation replacement, and layout collision resolution.
7. Run `dart format lib/models/tab_model.dart lib/models/app_config.dart lib/app/main_local.dart lib/app/main_ssh.dart test/models` and `flutter test test/models`.

### Task 4: Wire a distinct Agent2 panel and controls

**Files:**
- Modify: `lib/widgets/ai_assistant_panel.dart`
- Modify: `lib/widgets/ai_assistant_panel_content.dart`
- Modify: `lib/widgets/ai_assistant_button.dart`
- Modify: `lib/app/main_chrome.dart`
- Modify: `lib/app/main_mobile.dart`
- Modify: `lib/app/main_views.dart`
- Modify/add: `test/widgets/ai_assistant_panel_test.dart`

1. Add optional panel identity/presentation fields to `AiAssistantOverlay`: title/badge, execution description, terminal-controls enabled flag, and an independent widget key. Keep defaults exactly matching Agent1.
2. For Agent2 show an experimental “Background execution” badge and its own cwd; hide/disable terminal injection and “send to terminal” affordances. It still has the same LLM, questions, permission/write cards, and normal agent loop.
3. Add an Agent2 toolbar/mobile toggle beside the existing Agent1 control. Do not add a global duplicate-command feature; both panels are independently prompted and compared by the user.
4. Build Agent2 as a second host around the terminal body only after applying the resolved opposite-dock layout. Supply Agent2's executor, Agent2 cwd-based filesystem adapter, separate terminal-lock notifier (which remains false for background execution), and Agent2 config layout callback.
5. Keep Agent1 wiring byte-for-byte semantically unchanged: its visible state, terminal sender, OSC status, command executor, and cwd adapter remain current behavior.
6. Widget-test independent toggles, two panel identities, Agent2 terminal-controls absence, and the layout collision rule.
7. Run `dart format lib/widgets/ai_assistant_panel.dart lib/widgets/ai_assistant_panel_content.dart lib/widgets/ai_assistant_button.dart lib/app/main_chrome.dart lib/app/main_mobile.dart lib/app/main_views.dart test/widgets` and `flutter test test/widgets/ai_assistant_panel_test.dart`.

### Task 5: Integrate, document v1 boundaries, and verify

**Files:**
- Modify: `README.md` or the relevant user-facing documentation
- Modify: `docs/superpowers/specs/2026-08-08-agent2-background-execution-design.md` only if implementation discovers an API adjustment
- Modify/add: relevant integration tests

1. Document supported v1 targets (macOS/Linux bash/zsh and live SSH) and explicit non-support for Windows, detached jobs, process-tree guarantees, and implicit terminal-cwd synchronization.
2. Add integration coverage that proves Agent1 remains terminal-targeted while Agent2 selects local/SSH background targets and that Agent2 cancellation leaves the visible terminal/SSH transport usable.
3. Run `flutter analyze`, `flutter test`, and `git diff --check`.
4. Manually validate: open Agent1 and Agent2 in one local tab; run a long Agent2 command; confirm no text appears in the terminal; cancel it; run an interactive terminal command; repeat on an SSH tab.
5. Review `git diff --check`, `git status --short`, and test output before reporting completion.

## Review checklist

- Agent1’s `TerminalCommandExecutor` path has no behavioral change.
- Agent2 has no silent fallback to terminal injection.
- stdout/stderr are drained concurrently and bounded.
- A late completion from a cancelled command cannot update a newer Agent2 turn.
- SSH cancellation closes only the per-command session.
- Two open panels cannot share one dock edge.
- Windows and persistent process trees are rejected/documented rather than falsely supported.

