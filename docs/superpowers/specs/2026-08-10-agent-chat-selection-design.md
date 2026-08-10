# Agent Chat Selection Design

## Goal

Allow users to drag-select and copy normal Agent conversation text with the
platform copy shortcut or selection menu.

## Scope

`AiAssistantOverlay` is shared by Agent1 and Agent2. The conversation viewport
will therefore expose the same selection behavior in both panels. The change
does not add per-message copy buttons, alter conversation persistence, or
change message contents.

## Design

Wrap the non-empty conversation `ListView.builder` in a Flutter
`SelectionArea`. This provides one selection registrar for user messages,
Markdown-rendered assistant replies, notices, errors, and adjacent message
content. Existing `SelectableText` widgets inside command and tool-result
cards remain unchanged and participate through Flutter's selection system.

The empty state and the input field stay outside the selection area. Scrolling,
message construction, and Agent loop behavior are unchanged.

## Verification

A widget-level structural test builds `AiAssistantContent` in Agent mode with a
message and asserts that the conversation `ListView` is nested under a
`SelectionArea`. Existing Agent panel tests guard scrolling and rendering.

