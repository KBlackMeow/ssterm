# Command Execution Refactor Plan

## Goal

Move command feedback formatting and terminal command capture out of widget/page state without changing command, safety, timeout, cancellation, or UI behaviour.

## Phase 1: Command Feedback

1. Add focused tests for empty output, tool metadata, capture truncation, and UTF-8 byte truncation.
2. Introduce `CommandFeedbackFormatter` as a pure Dart module.
3. Switch the agent loop to the formatter and remove its private implementation.
4. Run focused tests and analysis.

## Phase 2: Command Execution

1. Add tests for command normalization and multiline shell wrapping.
2. Introduce `CommandExecutionTarget` with terminal, output pipe, command sender, and raw-byte sender.
3. Introduce `TerminalCommandExecutor` and move safety preflight plus OSC 133 capture behind its interface.
4. Add deterministic executor tests for success, cancellation, timeout recovery, and split-target isolation.
5. Move sentinel fallback after its existing behaviour is covered.
6. Replace `_executeAndCapture` with target selection plus one executor call.

## Phase 3: Agent Workflow

1. Add widget tests for dangerous-command approve, reject, and stale generation behaviour.
2. Consolidate the shared approval workflow used by manual and automatic execution.
3. Split streaming, write-proposal, and command-loop extensions only after functional extraction.

## Constraints

- Every step keeps the application runnable.
- Existing timeout values, logs, protocol markers, safety wording, and UI state remain unchanged.
- Generated files and xterm parser/terminal modules are out of scope.
