---
name: disk-space
description: Diagnose "no space left on device" and full-disk situations top-down — start at filesystem usage, drill into the full mount, find the heaviest paths, classify them by safe-to-delete category, and propose cleanup actions without deleting anything unilaterally.
when_to_use: the error mentions "No space left on device", "ENOSPC", "disk full", "write failed", "out of disk"; OR the user says "df shows 100%", "why is my disk full", "what's eating my disk", "free up space".
---

# Disk-Space Playbook

A disk / filesystem is full or near full.  Job: find what's eating it, classify by risk, propose cleanup — **never delete files without explicit user confirmation**.  A wrong `rm -rf` here is often unrecoverable.

## Step 1 — Top-level filesystem usage (ONE command)

```sh
df -h
```

This shows every mounted filesystem with its size, used, available, and percentage.  Read the output carefully:

- A mount at **100% on `/`** = system-wide problem, most cleanup candidates apply.
- A mount at **100% on `/var`**, **`/home`**, **`/data`**, etc. = problem is scoped, drill only into that mount.
- **Inode exhaustion** is a SEPARATE failure mode that `df -h` does NOT show.  If `df -h` shows free space but writes are still failing with `ENOSPC`, run `df -ih` to check inode usage — millions of tiny files can exhaust inodes while bytes remain free.
- macOS may show `/System/Volumes/Data` as the real user-data mount; the `/` Apple-Sealed System Volume is read-only and not the culprit.

If multiple mounts are full, pick the one the error message points at; if no error message, pick the highest-percentage user-writable mount.

## Step 2 — Find the heaviest directories in the full mount (ONE command, OS-aware)

Replace `<MOUNT>` with the path from step 1 (e.g. `/`, `/var`, `/home`).

### Linux / macOS — top-level under the mount

```sh
sudo du -h -d 1 -x <MOUNT> 2>/dev/null | sort -h | tail -20
```

- `-h` = human-readable sizes.
- `-d 1` = only one level deep (top dirs under the mount).  On older BSD `du` use `-d 1` too; on GNU you can also write `--max-depth=1`.
- `-x` = **don't cross filesystem boundaries** — critical, otherwise you'll double-count or wander into `/proc`, `/sys`, network mounts.
- `2>/dev/null` = swallow permission-denied noise on dirs you can't read.
- `sort -h` = sort by the human-readable size column (GNU sort; macOS sort supports `-h` since 10.10).
- `tail -20` = biggest 20.

### Drilling deeper

Once Step 2 names the offender directory, repeat with the next level:

```sh
sudo du -h -d 1 -x <OFFENDER_DIR> 2>/dev/null | sort -h | tail -20
```

Do **at most 3 levels of drill-down per turn** — past that, you're guessing.  Surface what you've found so far and ask the user.

## Step 3 — Classify what you found

Cross-reference the heavy paths against this table.  The category drives the cleanup recommendation.

| Path / pattern | Category | Typical safe action |
|---|---|---|
| `/var/log/**`, `*.log`, `*.log.[0-9]+`, `*.log.gz` | Rotated logs | Truncate live logs (`sudo truncate -s 0 <file>`); delete `.gz` archives older than 30 days. NEVER `rm` a log file an active process is writing — use `truncate`. |
| `/var/log/journal/**` (Linux systemd) | Journal | `sudo journalctl --vacuum-size=500M` (keeps recent, drops old). |
| `/var/lib/docker/**` (Linux) | Docker images/volumes | `docker system df` to see breakdown, then `docker system prune -a --volumes` (DESTRUCTIVE — confirm). |
| `~/Library/Caches/**` (macOS), `~/.cache/**` (Linux) | App caches | Generally safe to delete; apps rebuild on next launch. |
| `~/.npm`, `~/.yarn`, `~/.pnpm-store`, `~/.cargo/registry/cache`, `~/.gradle/caches` | Package manager caches | Safe; tools re-download on next install. |
| `**/node_modules` | Project deps | Safe per project (run `npm install` to restore).  Across many projects, use `find . -name node_modules -type d -prune -exec du -sh {} +` first. |
| `**/.git/objects/pack/**` huge | Git repo bloat | `git gc --aggressive` may help; don't delete pack files directly. |
| `~/Downloads`, `~/Desktop`, `/tmp` | User staging | Ask user — these often have things they care about. |
| `/private/var/folders/**` (macOS) | System temp / DerivedData via Xcode | `xcrun simctl delete unavailable` and clearing `~/Library/Developer/Xcode/DerivedData` often reclaims tens of GB. |
| Database data dirs (`/var/lib/postgresql`, `/var/lib/mysql`, MongoDB data path) | Database storage | NEVER delete files directly.  Use the DB's own tooling (`VACUUM FULL`, drop old tables, etc.). |
| Core dumps (`/var/lib/systemd/coredump`, `core.*`, `*.core`) | Crash dumps | Usually safe to delete; copy first if you might want to debug. |
| Unknown large file | Unclassified | Show the user, ask. |

## Step 4 — Present the top offenders + a menu, do not delete

End the turn with `[ASK_USER]` and show the user:

1. Which mount is full (`df -h` line).
2. The 3–5 heaviest paths found.
3. Per offender: classification + the **exact command** you would run to clean it.
4. Estimated reclaimable bytes per option.

Example response shape:

> `/` is at 97% (475 GB used / 500 GB).  Top offenders:
>
> | Path | Size | Category | Cleanup |
> |---|---|---|---|
> | `/var/lib/docker` | 180 GB | Docker images/volumes | `docker system prune -a --volumes` (frees ~150 GB, DESTRUCTIVE to stopped containers) |
> | `/var/log/journal` | 22 GB | systemd journal | `sudo journalctl --vacuum-size=500M` (frees ~21 GB) |
> | `~/.cache` | 8 GB | App caches | `rm -rf ~/.cache/*` (frees ~8 GB, safe) |
>
> Which would you like me to run?  I won't touch anything without your go-ahead.

Wait for the user's choice before running any deletion.

## Special cases

### Inode exhaustion (writes fail despite free bytes)

If `df -ih` shows a mount near 100% inodes, the culprit is usually millions of tiny files.  Find them:

```sh
sudo find <MOUNT> -xdev -type d -exec sh -c 'echo "$(ls -1 "$1" 2>/dev/null | wc -l) $1"' _ {} \; 2>/dev/null | sort -n | tail -20
```

Common offenders: mail spools, session dirs (`/var/lib/php/sessions`), npm install artifacts in `node_modules`, build caches.

### The file is "deleted" but space isn't freed

If a process has an open file handle to a deleted file, the inode survives until the handle closes.  Find these:

```sh
sudo lsof +L1 2>/dev/null | head -30
```

The fix is to restart the process holding the handle (or `truncate -s 0` the file's `/proc/<pid>/fd/<n>` entry on Linux).

## Anti-patterns

- **`rm -rf /` or `rm -rf /*`** — never run, never suggest, never even partially type.
- **`rm -rf /var/log/*`** — deletes log files that running daemons have open; they keep writing to phantom inodes and don't release space.  Use `truncate` instead.
- **Deleting from a database data directory** — corrupts the DB.  Always use the DB's own management tools.
- **`du` without `-x`** — wanders across mounts, double-counts, hangs on network filesystems.
- **Reporting paths without sizes** — the user can't prioritize without knowing reclaimable bytes.

## Stop conditions

- `[TASK_COMPLETE]` only after: user picked a cleanup, you ran it, and a follow-up `df -h` shows the mount is meaningfully below 100%.
- `[ASK_USER]` after presenting the offender menu, OR if `du` reveals data the user clearly cares about (e.g. their own `~/Documents`).
