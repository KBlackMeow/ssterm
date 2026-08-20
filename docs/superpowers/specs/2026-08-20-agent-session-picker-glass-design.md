# Agent Session Picker: Glass Cards and Safe Deletion

## Goal

Make the Agent panel's **Continue session** picker visually consistent with the
new-tab glass treatment, and allow a user to delete an inactive saved session.

## Scope

- Replace the stock `AlertDialog`/`ListTile` session picker with a glass
  surface that uses the shared `FrostedGlassSurface` styling.
- Render each available session as a selectable glass card with title and
  localised last-updated timestamp.
- Put a delete action on every rendered session card. Deletion is immediate;
  there is no confirmation dialog.
- Retain the current session when any deletion operation fails.

## Ownership and Safety

`AgentSessionRegistry.listAvailable()` remains the presentation filter, so a
session leased by an Agent tab is not shown and therefore has no delete
control. A delete click invokes `AgentSessionRegistry.delete(id)`, which
rechecks the lease before changing the registry. If another tab acquires the
session during this interval, the deletion is rejected and the picker displays
the existing unavailable-session notice.

## Interaction

Selecting a card continues that session using the existing acquire-before-
release lifecycle. Selecting its delete control stops the parent card's tap,
deletes that session from the registry, and removes the card from the picker.
When no available cards remain, the existing empty-state copy is displayed.

## Visual Design

The picker is a transparent Material dialog whose content is a
`FrostedGlassSurface`. Session cards use a slightly translucent neutral fill,
rounded corners, a subtle border, and hover feedback. The delete icon is
compact, has a descriptive tooltip, and adopts a muted destructive color only
on hover. All text reads colors through `AppColors` so the result remains
legible across terminal themes.

## Tests

- Widget coverage proves the picker uses glass styling and renders a delete
  affordance for available sessions.
- Service coverage preserves rejection of deletion when a session is leased.
- Widget/source coverage verifies a failed deletion reports the unavailable
  session state without selecting or replacing the active session.
