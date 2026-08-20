# Agent Explicit Sessions

## Goal

Give every newly opened Agent panel its own empty conversation session.  Users
may explicitly continue a saved session, but a saved session can be attached
to only one open Agent tab at a time.  This prevents same-shell and same-cwd
tabs from restoring or overwriting each other's history.

## Problem

The current session id is derived from the filesystem-adapter label, cwd, and
execution environment.  Two local zsh tabs opened in the same directory
produce the same id and therefore load and save the same snapshot.  Their
Agent history appears duplicated and concurrent saves can overwrite one
another.

## Session model

Each Agent session has a generated opaque id and persisted metadata:

- `id`: random, filesystem-safe identifier.
- `createdAt` and `updatedAt`: UTC timestamps.
- `title`: an initially generic display name, updated from the first user
  prompt with a bounded plain-text preview.

Session transcript snapshots continue to use the existing per-session files.
A separate atomic registry stores metadata and the ids of sessions that are
currently locked.  A lock is process-local runtime state; it is never written
to disk, so an app restart releases every lock safely.

## Lifecycle

### New tab

When an Agent overlay is created for a terminal tab, it creates and locks a
new empty session.  It does not automatically search for or restore a saved
session based on shell, cwd, tab title, or environment.

### Continue session

The Agent header exposes a session action that lists saved sessions that are
not currently locked.  Each row shows its title and last-updated time.  The
user chooses one explicitly.

Before switching:

1. Persist the current session's idle transcript if applicable.
2. Release its lock.
3. Atomically acquire the selected session's lock.
4. Clear the current in-memory transcript and restore the selected snapshot.

If lock acquisition fails because another Agent tab selected it first, leave
the current session attached and show a short unavailable notice.  The active
Agent task must be stopped before a session switch; the control is disabled
while the Agent is busy or awaiting an approval decision.

### Closing a tab

Disposing an Agent overlay persists its current idle session snapshot and
releases its session lock.  The session stays in the registry and can later
be continued by one other tab.

### New button

The Agent header adds a `New` action.  It is disabled while the Agent is busy
or paused.  It persists the current session, releases its lock, creates a new
empty session, locks it, and clears the in-memory transcript.  The old
session remains available from Continue session.

### Clear button

`Clear` keeps its existing role: it removes the current session's transcript
and output artifacts, keeps that session id and its lock, and leaves the user
in the same now-empty session.  It does not create a new session or alter any
other session.

### Delete session

The Continue-session list provides a destructive delete action for unlocked
sessions only.  It requires confirmation, then deletes the snapshot, output
artifacts, and registry entry.  The currently active session cannot be
deleted from this list; use `Clear` to empty it or `New` to leave it first.

## UI

The Agent header shows the current session's short title and two compact
actions:

- `New`: begin a separate empty session.
- `Continue`: open the available-session picker.

The picker has an empty state, a time-ordered list of available sessions, and
per-row delete.  Locked sessions are excluded rather than shown as selectable
items.  No automatic keyword retrieval or background injection of history is
introduced.

## Compatibility and migration

- Existing scope-derived snapshots are not auto-opened by new tabs.  On first
  startup after upgrade, the registry imports each valid existing snapshot as
  an unlocked legacy session, using its file timestamp for `updatedAt` and a
  generic title.  The original snapshot filename remains valid and is mapped
  to a registry id; no transcript content is rewritten during import.
- If legacy import cannot parse an entry, it leaves the file untouched and
  skips it; the existing session-store quarantine behavior still applies when
  that session is later opened.
- A missing/corrupt registry is rebuilt from valid snapshots.  This favors
  preserving recoverable history over retaining UI metadata.

## Tests

- Two same-cwd local/zsh tabs receive different new session ids and empty
  histories.
- A saved unlocked session can be acquired and restored by one tab.
- A session held by one tab cannot be selected by another until released.
- New persists/releases the former session and creates a distinct empty,
  locked session.
- Clear removes only the active session's transcript/artifacts while retaining
  its id and lock.
- Disposing an overlay releases its lock.
- Registry migration discovers valid legacy snapshots without auto-restoring
  any into a new tab.
- Delete removes an unlocked session's registry, snapshot, and artifacts, and
  rejects deletion of a locked session.

## Out of scope

- Automatic history lookup by keyword or semantic search.
- Sharing one live Agent session among multiple tabs.
- Synchronizing session locks between separate app processes or devices.
- Changing Stop semantics; Stop ends work in the active session but does not
  release it.
