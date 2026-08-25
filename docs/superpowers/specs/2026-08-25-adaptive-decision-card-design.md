# Adaptive Decision Card Design

## Goal

Make the experimental adaptive-decision pipeline observable in the Agent
transcript without changing model prompts, tool permissions, or execution
semantics.

## Placement

When a deep route is selected, insert one client-side card immediately after
the user's message and before the first Agent reply. The same card updates in
place as the run moves through planning, critique, execution, verification,
or fallback.

## Content

The card shows the deep route and its trigger, an in-progress stage, then the
recommended candidate summary after planning succeeds. If planning cannot
produce a valid plan, it states that the run continued on the standard loop.
After verification, it records whether evidence was confirmed, pending, or
sent back for recovery.

## Boundaries

Only deep-routed tasks create a card. Fast requests remain unchanged. The
card is client-only and must not enter `_conversationHistory`; the existing
`<decision_plan>` prompt injection remains the sole model-facing plan data.

## Validation

Widget/source tests verify the transcript message type, placement, lifecycle
updates, and explicit fallback text. Existing adaptive-decision policy tests
continue to cover routing and plan parsing.
