# Command Purpose on Result Cards

## Goal

Show the AI-supplied execution purpose on every completed command result card, regardless of whether the command risk is normal, warning, or dangerous.

## Design

Add an optional `commandPurpose` value to `_ChatMessage`. The agent loop copies `ToolCall.reason` into this value when it creates the system/result message. `_buildAgentMessage` forwards the value to `_CommandResultCard`, which renders a persistent line below the command header.

The visible copy is `执行目的：<purpose>` when a non-empty purpose is supplied and `执行目的：AI 未提供` otherwise. Risk reason remains in the risk badge tooltip; execution purpose and risk explanation are separate concepts.

## Constraints

- Apply uniformly to normal, warning, and dangerous command results.
- Do not infer a purpose from the command string.
- Do not change command execution, approval, risk classification, or LLM feedback.
- Preserve the existing purpose text on approval cards.

## Testing

Extend the panel invariant test to verify the purpose is carried through the message model, loop, content builder, and result-card widget, including the missing-purpose fallback copy.
