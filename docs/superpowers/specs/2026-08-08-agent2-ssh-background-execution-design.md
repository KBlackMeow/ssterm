# Agent2 SSH background execution design

Agent2 SSH commands use a new non-PTY `SSHClient.execute` session per command. They never write to the interactive SSH session backing the visible terminal.

The host prefixes a safely single-quoted `cd <agent2 cwd> &&` command. stdout and stderr streams are subscribed immediately, drained concurrently, and combined into the normal `CommandResult` only after streams and `session.done` complete.

Cancellation and timeout send TERM then close only that command session. The shared SSH client, SFTP client, forwarding service, and visible terminal session remain open. Disconnected SSH returns an explicit result and never falls back to terminal injection.

All completed results pass through the existing Agent2 command history wrapper and are appended with complete output to JSONL.

