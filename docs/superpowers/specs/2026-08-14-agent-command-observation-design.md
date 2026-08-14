# Agent command observation design

## Goal

Make Agent command execution observable while it runs, preserve a user's
position in the transcript, and stop commands that are likely stuck without
interrupting normal long-running work.

## Transcript scrolling

The Agent transcript auto-scrolls only when the viewport is already at (or
within a small threshold of) its bottom. New chat messages, command updates,
and status changes must not move a user who has scrolled up to inspect earlier
content. A user who returns to the bottom resumes automatic following.

## Live command card

The command-result card is created as soon as a shell command starts. While
the command runs, it displays a running state and the latest three logical
lines from combined stdout/stderr. The display refreshes as output arrives.
When the command exits, is cancelled, or times out, the card keeps its final
three lines and adds the resulting exit/cancellation status.

## Observation protocol

The background command executor exposes incremental output and inactivity
events to its caller for both local and SSH commands. The panel forwards each
output update to the command card and makes the same latest-three-line window
available to the Agent as command feedback.

After 60 seconds without output, the executor reports a silence checkpoint
containing the command, elapsed duration, and current last-three-line window.
The Agent receives this checkpoint and decides whether to continue observing
for another 60-second interval or stop the command. A continue decision resets
the inactivity window; a stop decision terminates the process/session using the
existing cancellation path. Active commands continue to run as long as they
produce output, subject to the existing total execution timeout and explicit
user cancellation.

## Boundaries and failure handling

The executor remains responsible for process ownership, bounded output,
termination, and final cleanup. The panel owns rendering and relaying events to
the Agent. If the Agent cannot provide a decision at a silence checkpoint, the
safe default is to stop the command rather than leave an unobserved process
running. Existing safety checks and the user stop control remain unchanged.

## Testing

Tests will cover:

- automatic scroll only when already following the bottom;
- latest-three-line extraction across fragmented stdout/stderr chunks;
- live command-card updates while a command is running;
- no silence checkpoint while output continues;
- the 60-second checkpoint's continue and stop paths;
- final status and output retention after completion or termination.
