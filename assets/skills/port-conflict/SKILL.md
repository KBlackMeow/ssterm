---
name: port-conflict
description: Diagnose "address already in use" / port-binding failures by locating the holding process, classifying it (known service vs ad-hoc), and recommending kill / stop / reassign actions — without killing anything unilaterally.
when_to_use: the error message mentions "address already in use", "EADDRINUSE", "bind: …", "port is already allocated", or the user says "port X is taken / occupied / busy / why can't I start on :NNNN".
---

# Port-Conflict Playbook

A process is already listening on the port the user wants.  Job: find out **who**, classify whether it's killable, and give the user a clear next-step menu.  **Never kill a process without explicit user confirmation** — the holder might be production.

## Step 1 — Extract the port number

From the error message or the user's prompt, isolate the integer port number (e.g. `8080`, `5432`).  Also note the bind address if specified (`127.0.0.1:8080` vs `0.0.0.0:8080` vs IPv6 `[::1]:8080`) — sometimes the conflict is on the wildcard address while loopback would have been free.

If the port isn't obvious, end with `[ASK_USER]`: "Which port?  The error mentions both 8080 and 8443."

## Step 2 — Identify the holder (ONE command, OS-aware)

Pick the FIRST available tool from this table — they're listed in order of preference per OS.  Run only ONE; if it fails, try the next on the following turn.

### macOS / Linux with `lsof` installed

```sh
lsof -nP -iTCP:<PORT> -sTCP:LISTEN
```

- `-n` = don't resolve IPs (faster, no DNS hang).
- `-P` = don't translate port→service name (we want the raw number).
- `-sTCP:LISTEN` = only listeners, not transient connections.

### Linux without `lsof` (modern, has `ss`)

```sh
ss -lntp 'sport = :<PORT>'
```

The `-p` flag needs root to show the process; if not root, you'll see `users:(("?"))` and need to escalate or fall back to `/proc`.

### Linux fallback (no `ss`, no `lsof`)

```sh
netstat -lntp 2>/dev/null | awk -v p=":<PORT>" '$4 ~ p {print}'
```

### UDP variant (rare but exists)

Swap `TCP→UDP` / `-iTCP→-iUDP` / `'sport = :…'` with `'udp sport = :…'`.  Most "port in use" complaints are TCP — only pivot here if step 2's TCP query found nothing.

## Step 3 — Resolve PID to a full process picture

Once you have a PID from step 2, run:

```sh
ps -p <PID> -o pid,ppid,user,etime,command
```

This shows:
- **ppid** — is it owned by `launchd` / `systemd` / `init` (1)?  Then it's a managed service, not an orphan.
- **user** — root-owned processes need `sudo` to kill.
- **etime** — uptime; minutes-old is probably your last dev server, days-old is probably a service.
- **command** — the actual binary + args, which is what classifies it in Step 4.

## Step 4 — Classify the holder

| Command pattern | Class | Recommended action |
|---|---|---|
| `nginx: master process` / `httpd` / `caddy` | Web server | `sudo systemctl stop nginx` (Linux) / `sudo brew services stop nginx` (macOS).  Confirm with user first. |
| `postgres -D …` / `mysqld` / `redis-server` | Database | DO NOT kill blindly — risk of data corruption mid-write.  Suggest graceful stop via init system. |
| `docker-proxy` or `com.docker.backend` | Docker port-forward | A container is publishing this port.  Run `docker ps --filter "publish=<PORT>"` and suggest `docker stop <container>`. |
| `node` / `python` / `ruby` / `go run` / `npm`/`yarn`/`pnpm` | Dev server (likely user's own) | Usually safe to `kill <PID>` (SIGTERM first; SIGKILL only after 5s).  Suggest checking shell history for which project launched it. |
| `ssh -L` / `ssh -R` | SSH tunnel | User probably set this up earlier; ask before killing — they may need to re-establish it. |
| Same binary as the user is trying to START | Stale instance (crashed parent, supervisor restarted) | Safe to kill; the new launch will replace it. |
| Unknown / proprietary | Unclassified | Show the user the `ps` line and ASK before any action. |

## Step 5 — Present a menu, do not act

End the turn with `[ASK_USER]` and offer 2–3 concrete options.  Example response shape:

> Port 8080 is held by PID 47291, owned by `youruser`:
>
>     node /Users/you/proj/dev-server.js (running 12m)
>
> This looks like a stale dev server from this morning.  Options:
> 1. Kill it: `kill 47291` (graceful) or `kill -9 47291` (force, last resort)
> 2. Start your new server on a different port (e.g. `PORT=8081 npm start`)
> 3. Leave it; tell me what you actually want to run

Wait for the user to choose before running any `kill`.

## Anti-patterns

- **`fuser -k <port>/tcp`** — kills without identification.  Don't.
- **`pkill -f node`** — overshoots; kills every node process on the box.  Don't.
- **Killing PID 1, or anything with `ppid=1` whose command starts with `/usr/sbin/` or `/usr/libexec/`** — that's an OS-managed service.  Stop it through its init system instead.
- **Assuming SIGTERM is enough for `kill -9` cases** — give SIGTERM 5 seconds first; only escalate if the process refuses.

## Stop conditions

- `[TASK_COMPLETE]` only after the user picked an option, you executed it, and a follow-up `lsof`/`ss` confirms the port is free (no listener).
- `[ASK_USER]` if classification is ambiguous or the holder looks production-managed.
