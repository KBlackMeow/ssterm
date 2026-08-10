# Agent clear button design

## Goal

Expose the existing Agent conversation clear action through a button in the
panel header.

## Behaviour

- Add a compact trash icon to the Agent header, before the dock-position
  toggle.
- Its tooltip is `Clear conversation`.
- Tapping it invokes the existing `_clearChat` callback with no confirmation.
- The existing clear behaviour remains authoritative: it cancels any active
  Agent run, clears visible messages and the input, and clears conversation
  history and loop status.

## Scope

No new state, persistence, or command-execution path is introduced. The
`/clear`, `/reset`, and `/new` slash commands continue to use the same clear
method.

## Verification

Widget/source coverage will assert that the header exposes the callback and
the overlay wires it to `_clearChat`; existing clear-state tests remain the
behavioural authority.
