# Terminal Query Responses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement deterministic, honest xterm/iTerm2-compatible terminal query responses so Fish starts normally in every SSTerm session.

**Architecture:** Extend the vendored xterm incremental parser with a bounded DCS parser and query callbacks. `Terminal` turns validated requests into responses through its existing `onOutput` channel; local PTY and SSH wiring therefore remain shared and platform-neutral. The Flutter host provides only display facts such as color or pixel metrics.

**Tech Stack:** Flutter/Dart, vendored `packages/xterm`, flutter_pty, dartssh2, flutter_test.

## Global Constraints

- Advertise only behavior SSTerm implements; never identify as iTerm2.
- One complete request produces one deterministic response, independent of chunking.
- Unknown, malformed, oversized, and platform-unavailable requests must have a safe negative/no-op result.
- Preserve macOS, Linux, and Windows transport behavior through `Terminal.onOutput`.
- Remove `no-query-term` only after the Fish startup fixture passes.

---

### Task 1: Bounded incremental DCS parsing

**Files:**
- Modify: `packages/xterm/lib/src/core/escape/parser.dart`
- Modify: `packages/xterm/lib/src/core/escape/handler.dart`
- Test: `packages/xterm/test/src/core/escape/parser_test.dart`

**Interfaces:**
- Produces: `void requestTermcap(List<String> hexNames)` on `EscapeHandler`.

- [ ] Write tests that feed `DCS +q 696e646e ST` as one chunk and byte-by-byte, and assert exactly one `requestTermcap(['696e646e'])` call.
- [ ] Run `flutter test packages/xterm/test/src/core/escape/parser_test.dart` and confirm the new tests fail because DCS is unparsed.
- [ ] Add `ESC P` handling, retain incomplete DCS until `ESC \\`, enforce a 4096-byte limit, and dispatch only `+q` requests split on `;` after ASCII-hex validation.
- [ ] Add handler tests for malformed hex, unterminated input, and an over-limit request; assert they issue no callback and do not consume following printable text.
- [ ] Run the parser suite and commit with `feat: parse terminal capability queries`.

### Task 2: Deterministic terminal capability profile and responses

**Files:**
- Modify: `packages/xterm/lib/src/core/escape/emitter.dart`
- Modify: `packages/xterm/lib/src/terminal.dart`
- Create: `packages/xterm/lib/src/core/terminal_capabilities.dart`
- Test: `packages/xterm/test/src/terminal_query_response_test.dart`

**Interfaces:**
- Produces: immutable `TerminalCapabilities` with `backgroundRgb`, `termName`, and supported termcap values.
- Produces: `Terminal(capabilities: ...)` response behavior through `onOutput`.

- [ ] Write failing tests for `CSI ? u`, `CSI > 0 q`, OSC 11, DA1/DA2, valid `indn`, and unsupported XTGETTCAP.
- [ ] Verify tests fail before implementation.
- [ ] Implement exact sequence formatting: disabled kitty keyboard response, honest SSTerm XTVERSION response, `rgb:rrrr/gggg/bbbb` background response, existing DA responses, `indn` termcap response, and DCS negative response for unsupported names.
- [ ] Test repeated queries and arbitrary chunk boundaries return byte-identical single responses.
- [ ] Run all `packages/xterm/test` and commit with `feat: respond to terminal capability queries`.

### Task 3: iTerm2-compatible feature reporting boundary

**Files:**
- Modify: `packages/xterm/lib/src/core/escape/parser.dart`
- Modify: `packages/xterm/lib/src/terminal.dart`
- Test: `packages/xterm/test/src/terminal_query_response_test.dart`
- Modify: `docs/XTERM_COMPAT.md`

**Interfaces:**
- Consumes: `TerminalCapabilities`.
- Produces: stable `OSC 1337;Capabilities=<feature-list> ST` response.

- [ ] Write a failing test for `OSC 1337;Capabilities ST` and assert only implemented capabilities are reported.
- [ ] Implement recognition and response, using the same ST terminator family as the request.
- [ ] Add negative tests proving unsupported iTerm2 image, file-transfer, profile, and clipboard commands are not advertised or executed.
- [ ] Document the supported iTerm2-compatible subset in `docs/XTERM_COMPAT.md`.
- [ ] Run query-response and existing OSC tests; commit with `feat: report supported terminal capabilities`.

### Task 4: Transport wiring and Fish regression coverage

**Files:**
- Modify: `lib/app/main_local.dart`
- Modify: `lib/app/main_ssh.dart`
- Modify: `lib/services/local_shell_wrapper.dart`
- Modify: `test/services/local_shell_wrapper_test.dart`
- Create: `test/services/fish_terminal_probe_test.dart`

**Interfaces:**
- Consumes: `Terminal.onOutput` responses from Tasks 1–3.
- Produces: identical forwarding to `Pty.write` and `SSHSession.stdin.add`.

- [ ] Write source/integration fixtures proving local and SSH input bindings forward terminal-generated responses exactly once.
- [ ] Add Fish startup fixture containing the observed DA, XTGETTCAP, OSC 11, XTVERSION, and keyboard query sequence; assert it receives its required responses.
- [ ] Remove `no-query-term` from `localShellStartupArguments` and the Fish wrapper only after the fixture passes.
- [ ] Run local-shell, SSH-wiring, and Fish tests; commit with `fix: let fish probe terminal capabilities`.

### Task 5: Compatibility audit

**Files:**
- Test: `packages/xterm/test`
- Test: `test/services/local_shell_wrapper_test.dart`
- Test: `test/services/ssh_shell_bootstrap_source_test.dart`
- Test: `test/io/output_pipe_test.dart`

- [ ] Run `flutter test packages/xterm/test`.
- [ ] Run `flutter test test/services/local_shell_wrapper_test.dart test/services/ssh_shell_bootstrap_source_test.dart test/io/output_pipe_test.dart`.
- [ ] Run `flutter analyze`.
- [ ] Run the complete project test suite on macOS; verify Windows/Linux source paths are covered by portable unit tests and platform guards.
- [ ] Inspect `git diff --check`, record platform limits in `docs/XTERM_COMPAT.md`, and commit final verification fixes if required.
